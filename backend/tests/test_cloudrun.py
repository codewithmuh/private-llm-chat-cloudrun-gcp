"""Cloud Run models: waking a sleeping GPU, its status, and ID tokens."""

from __future__ import annotations

from datetime import timedelta

import httpx
import pytest
from django.utils import timezone

from apps.llm import wake
from apps.llm.models import LLMModel
from apps.llm.providers import google_auth

pytestmark = pytest.mark.django_db

URL = "https://qwen-1.us-central1.run.app"


@pytest.fixture(autouse=True)
def fake_token(monkeypatch):
    monkeypatch.setattr(wake, "id_token", lambda audience: f"token-for-{audience}")


@pytest.fixture
def model() -> LLMModel:
    return LLMModel.objects.create(slug="qwen", name="Qwen", provider="cloudrun", base_url=f"{URL}/v1")


def health(status: int, seen: list | None = None) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request)
        return httpx.Response(status)

    return httpx.MockTransport(handler)


def test_check_records_an_awake_service(model):
    seen: list[httpx.Request] = []
    assert wake.check(model, transport=health(200, seen)) is True
    assert str(seen[0].url) == f"{URL}/health"
    assert seen[0].headers["authorization"] == f"Bearer token-for-{URL}"
    model.refresh_from_db()
    assert model.awake_at is not None and model.public_status()[0] == "ready"


def test_a_quick_check_that_times_out_just_means_not_yet(model):
    def slow(request):
        raise httpx.ReadTimeout("still starting")

    assert wake.check(model, transport=httpx.MockTransport(slow)) is False
    model.refresh_from_db()
    assert model.last_error == ""


def test_a_long_check_that_fails_is_reported(model):
    assert wake.check(model, timeout=30, transport=health(403)) is False
    model.refresh_from_db()
    assert "HTTP 403" in model.last_error
    status, detail = model.public_status()
    assert status == "failed" and "HTTP 403" in detail


def test_status_follows_the_life_of_a_cloud_run_model(model):
    assert model.public_status()[0] == "stopped"  # never seen: asleep
    model.wake_requested_at = timezone.now()
    assert model.public_status()[0] == "starting"
    model.wake_requested_at, model.awake_at = None, timezone.now()
    assert model.public_status()[0] == "ready"
    model.awake_at = timezone.now() - timedelta(minutes=30)  # Cloud Run has scaled it to zero by now
    assert model.public_status()[0] == "stopped"


def test_start_wakes_in_the_background_once(model, monkeypatch):
    threads = []

    class FakeThread:
        def __init__(self, target, name, daemon):
            threads.append(name)
            self.target = target

        def start(self):
            pass  # don't actually wait for a GPU

    monkeypatch.setattr(wake.threading, "Thread", FakeThread)
    wake.start(model)
    wake.start(LLMModel.objects.get(pk=model.pk))  # a second message while it wakes
    assert threads == ["wake-qwen"]
    assert LLMModel.objects.get(pk=model.pk).public_status()[0] == "starting"


def test_the_model_list_notices_when_a_wake_finished(auth_client, model, monkeypatch):
    LLMModel.objects.filter(pk=model.pk).update(wake_requested_at=timezone.now())
    calls = []

    def answered(m, **kwargs):
        calls.append(m.slug)
        LLMModel.objects.filter(pk=m.pk).update(awake_at=timezone.now(), wake_requested_at=None)
        m.awake_at, m.wake_requested_at = timezone.now(), None
        return True

    monkeypatch.setattr(wake, "check", answered)
    assert auth_client.get("/api/models/").json()[0]["status"] == "ready"
    auth_client.get("/api/models/")  # an awake model isn't checked again
    assert calls == ["qwen"]


def test_wake_endpoint(auth_client, model, monkeypatch):
    started = []
    monkeypatch.setattr(wake, "start", lambda m: started.append(m.slug))
    res = auth_client.post_json("/api/models/qwen/wake/")
    assert res.status_code == 202
    assert started == ["qwen"]


def test_id_tokens_are_cached_until_shortly_before_they_expire(monkeypatch):
    import time

    google_auth._cache.clear()
    fetched = []

    def fetch(audience):
        fetched.append(audience)
        return f"token-{len(fetched)}", time.time() + 3600

    monkeypatch.setattr(google_auth, "_fetch", fetch)
    assert google_auth.id_token(URL) == "token-1"
    assert google_auth.id_token(URL) == "token-1"  # cached
    google_auth._cache[URL] = ("old", time.time() + 60)  # expires within 5 minutes
    assert google_auth.id_token(URL) == "token-2"
    assert fetched == [URL, URL]
