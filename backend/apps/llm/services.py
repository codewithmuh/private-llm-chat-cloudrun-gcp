"""Model lookups and the "is this model ready?" check done before each chat."""

from __future__ import annotations

import json
import logging
from pathlib import Path

from django.conf import settings
from django.db import transaction

from apps.common.errors import ApiError

from . import wake
from .models import LLMModel

log = logging.getLogger(__name__)


def get_model(slug: str | None, user=None) -> LLMModel:
    if slug:
        model = LLMModel.objects.filter(slug=slug, enabled=True).first()
        if model is None:
            raise ApiError(
                "That model is not available.",
                code="unknown_model",
                status_code=400,
                fields={"model": "Unknown model."},
            )
        return model
    model = LLMModel.default_for(user)
    if model is None:
        raise ApiError(
            "No models are configured yet. Add one with LLM_MODELS or in /admin/.",
            code="no_models",
            status_code=503,
        )
    return model


def ensure_ready(model: LLMModel) -> None:
    """Raise a 503 the UI understands if the model's GPU is asleep (and wake it).

    Only Cloud Run models sleep. Any other model is "ready": if its server is
    down, the call itself fails with a clear message.
    """
    model.touch()
    if not model.is_cloudrun or wake.is_awake(model):
        return
    wake.start(model)
    _, detail = model.public_status()
    raise ApiError(
        detail or "The model is starting. Try again in a minute.",
        code="model_starting",
        status_code=503,
        extra={"retry_after": 30},
    )


# ------------------------------------------------------------------ syncing --

_FIELDS = {
    # json key          -> (model field, default)
    "name": ("name", None),
    "description": ("description", ""),
    "provider": ("provider", None),
    "model_id": ("model_id", ""),
    "base_url": ("base_url", ""),
    "api_key": ("api_key", ""),
    "hourly_cost_usd": ("hourly_cost_usd", None),
    "vision": ("vision", False),
    "ocr": ("ocr", False),
    "context_window": ("context_window", 8192),
    "max_output_tokens": ("max_output_tokens", 2048),
    "temperature": ("temperature", 0.7),
    "params": ("params", {}),
    "default": ("is_default", False),
    "sort": ("sort", 100),
    "enabled": ("enabled", True),
}


def configured_models() -> str:
    """LLM_MODELS if set, else the contents of LLM_MODELS_FILE, else []."""
    if settings.LLM_MODELS.strip():
        return settings.LLM_MODELS
    if settings.LLM_MODELS_FILE:
        path = Path(settings.LLM_MODELS_FILE)
        if not path.is_file():
            raise ValueError(f"LLM_MODELS_FILE={path} does not exist")
        return path.read_text()
    return "[]"


def parse_models_config(raw: str | list) -> list[dict]:
    entries = json.loads(raw) if isinstance(raw, str) else raw
    if not isinstance(entries, list):
        raise ValueError("LLM_MODELS must be a JSON list")
    cleaned = []
    seen = set()
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict) or not entry.get("id"):
            raise ValueError(f"LLM_MODELS[{i}] needs an 'id'")
        slug = str(entry["id"])
        if slug in seen:
            raise ValueError(f"LLM_MODELS has two models with id {slug!r}")
        seen.add(slug)
        provider = entry.get("provider")
        if provider not in LLMModel.Provider.values:
            raise ValueError(f"LLM_MODELS[{slug}]: provider must be one of {LLMModel.Provider.values}")
        if provider in ("openai", "cloudrun") and not entry.get("base_url"):
            raise ValueError(f"LLM_MODELS[{slug}]: a '{provider}' provider needs 'base_url'")
        if provider == "cloudrun" and not str(entry["base_url"]).startswith("https://"):
            raise ValueError(f"LLM_MODELS[{slug}]: a 'cloudrun' base_url is the service's https:// URL + /v1")
        if not isinstance(entry.get("params", {}), dict):
            raise ValueError(f'LLM_MODELS[{slug}]: params must be a JSON object, e.g. {{"top_p": 0.8}}')
        cleaned.append(entry)
    return cleaned


@transaction.atomic
def sync_models(raw: str | list | None = None) -> dict[str, list[str]]:
    """Make the database match LLM_MODELS.

    Models from LLM_MODELS are created or updated. Env-managed models that
    disappeared from the list are disabled (not deleted: old conversations
    still name them). Models created in /admin/ are left alone.
    """
    entries = parse_models_config(configured_models() if raw is None else raw)
    result = {"created": [], "updated": [], "disabled": []}
    for entry in entries:
        defaults = {"managed_by_env": True}
        for key, (field, default) in _FIELDS.items():
            if key in entry:
                defaults[field] = entry[key]
            elif default is not None:
                defaults[field] = dict(default) if isinstance(default, dict) else default
        defaults.setdefault("name", entry["id"])
        _, created = LLMModel.objects.update_or_create(slug=entry["id"], defaults=defaults)
        result["created" if created else "updated"].append(entry["id"])

    listed = {e["id"] for e in entries}
    stale = LLMModel.objects.filter(managed_by_env=True, enabled=True).exclude(slug__in=listed)
    result["disabled"] = list(stale.values_list("slug", flat=True))
    stale.update(enabled=False, is_default=False)

    # Exactly one default among enabled models, if any claims it.
    defaults = LLMModel.objects.filter(enabled=True, is_default=True).order_by("sort", "name")
    if defaults.count() > 1:
        keep = defaults.first()
        defaults.exclude(pk=keep.pk).update(is_default=False)
    return result
