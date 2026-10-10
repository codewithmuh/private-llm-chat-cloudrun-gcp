"""Waking a sleeping Cloud Run GPU, and knowing when it's awake.

Cloud Run scales an idle model service to zero instances: no GPU, no cost.
Any request wakes it: Cloud Run starts an instance (~5 s), vLLM loads the
weights (~1-2 min), and only then does the request get its answer.

Holding a chat open for two minutes with no sign of life is a bad experience,
so instead (the same flow the UI has for any starting model):

  1. Before a chat, `is_awake()` asks GET /health with a short timeout.
  2. Asleep? `start()` sends one GET /health from a background thread with a
     long timeout. That request is what makes Cloud Run start an instance, and
     it returns once vLLM is ready. The chat gets a 503 "model_starting"; the
     UI shows "Waking up the GPU" and polls GET /api/models/.
  3. While a wake is in progress, the model list asks /health again (at most
     every few seconds), and the status flips to "ready".
"""

from __future__ import annotations

import logging
import threading

import httpx
from django.conf import settings
from django.core.cache import cache
from django.db import connection
from django.utils import timezone

from .models import LLMModel
from .providers.cloudrun import service_root
from .providers.google_auth import id_token

log = logging.getLogger(__name__)

QUICK_TIMEOUT = 3.0
RECHECK_EVERY_SECONDS = 5


def check(model: LLMModel, timeout: float = QUICK_TIMEOUT, transport: httpx.BaseTransport | None = None) -> bool:
    """True if the service answered GET /health; records when it did."""
    root = service_root(model.base_url)
    try:
        headers = {"Authorization": f"Bearer {id_token(root)}"}
        with httpx.Client(timeout=httpx.Timeout(timeout, connect=min(timeout, 10.0)), transport=transport) as client:
            response = client.get(f"{root}/health", headers=headers)
        healthy = response.status_code == 200
        problem = "" if healthy else f"HTTP {response.status_code} from {root}/health"
    except httpx.TimeoutException:
        return False  # still starting
    except Exception as exc:  # noqa: BLE001 - token or network problems
        healthy, problem = False, f"{type(exc).__name__}: {str(exc)[:200]}"
    now = timezone.now()
    if healthy:
        LLMModel.objects.filter(pk=model.pk).update(awake_at=now, wake_requested_at=None, last_error="")
        model.awake_at, model.wake_requested_at, model.last_error = now, None, ""
    elif problem and timeout > QUICK_TIMEOUT:
        # A long check that failed (not just "not yet"): tell the UI why.
        LLMModel.objects.filter(pk=model.pk).update(last_error=problem[:500], last_error_at=now, wake_requested_at=None)
        model.last_error, model.last_error_at, model.wake_requested_at = problem[:500], now, None
        log.warning("model did not wake", extra={"model": model.slug, "reason": problem})
    return healthy


def is_awake(model: LLMModel) -> bool:
    return model.probably_awake() or check(model)


def start(model: LLMModel) -> None:
    """Wake the service in the background (once at a time per model)."""
    if model.waking():
        return
    now = timezone.now()
    LLMModel.objects.filter(pk=model.pk).update(wake_requested_at=now, last_error="", last_error_at=None)
    model.wake_requested_at, model.last_error = now, ""

    def run() -> None:
        try:
            check(LLMModel.objects.get(pk=model.pk), timeout=settings.MODEL_WAKE_SECONDS * 5)
        except Exception:  # noqa: BLE001 - a background thread must not crash the worker
            log.exception("wake failed", extra={"model": model.slug})
        finally:
            connection.close()  # this thread's own database connection

    threading.Thread(target=run, name=f"wake-{model.slug}", daemon=True).start()


def refresh(model: LLMModel) -> None:
    """While a wake is in progress, check whether it's done (rate-limited)."""
    if not (model.is_cloudrun and model.waking()):
        return
    if cache.add(f"wake-check:{model.pk}", 1, timeout=RECHECK_EVERY_SECONDS):
        check(model)
