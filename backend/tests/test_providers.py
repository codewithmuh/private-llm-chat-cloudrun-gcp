"""Talking to model servers: stream parsing, OpenAI-compatible HTTP, Cloud Run."""

from __future__ import annotations

import json

import httpx
import pytest

from apps.llm.providers.base import ChatRequest, ChunkParser, ProviderError, Usage, split_lines
from apps.llm.providers.cloudrun import CloudRunProvider, service_root
from apps.llm.providers.openai_compat import OpenAICompatibleProvider


def chunk(content=None, reasoning=None, usage=None) -> str:
    delta = {}
    if content is not None:
        delta["content"] = content
    if reasoning is not None:
        delta["reasoning_content"] = reasoning
    body = {"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": delta}] if delta else []}
    if usage:
        body["usage"] = usage
    return json.dumps(body)


def test_parser_handles_sse_and_json_lines():
    parser = ChunkParser()
    out = []
    for line in [
        f"data: {chunk('Hel')}",
        "",
        ": keep-alive",
        chunk("lo"),
        f"data: {chunk(usage={'prompt_tokens': 5, 'completion_tokens': 2})}",
        "data: [DONE]",
    ]:
        out += parser.feed_line(line)
    assert "".join(out) == "Hello"
    assert parser.done
    assert parser.usage == Usage(5, 2)


def test_parser_wraps_reasoning_in_think_tags():
    parser = ChunkParser()
    out = parser.feed_line(chunk(reasoning="Let me think.")) + parser.feed_line(chunk("Answer."))
    assert "".join(out) == "<think>\nLet me think.\n</think>\n\nAnswer."


def test_parser_raises_on_error_chunks():
    with pytest.raises(ProviderError) as info:
        ChunkParser().feed_line(
            'data: {"object": "error", "message": "This model\'s maximum context length is 4096 tokens"}'
        )
    assert info.value.code == "context_too_long"


def test_split_lines_reassembles_packets():
    assert list(split_lines([b"data: a", b"bc\ndata: d", b"ef\n", b"tail"])) == ["data: abc", "data: def", "tail"]


def test_openai_compatible_provider():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["auth"] = request.headers.get("authorization")
        seen["body"] = json.loads(request.content)
        body = "\n\n".join(
            f"data: {c}"
            for c in [chunk("Hi"), chunk(" there"), chunk(usage={"prompt_tokens": 3, "completion_tokens": 2})]
        )
        return httpx.Response(200, text=body + "\n\ndata: [DONE]\n\n", headers={"content-type": "text/event-stream"})

    provider = OpenAICompatibleProvider(
        "http://llm:8000/v1/", "my-model", api_key="k", transport=httpx.MockTransport(handler)
    )
    result = provider.complete(ChatRequest(messages=[{"role": "user", "content": "hey"}], max_tokens=10))
    assert result.text == "Hi there"
    assert result.usage.completion_tokens == 2
    assert seen["url"] == "http://llm:8000/v1/chat/completions"
    assert seen["auth"] == "Bearer k"
    assert seen["body"]["model"] == "my-model" and seen["body"]["stream"] is True


def test_openai_compatible_provider_errors():
    def handler(request):
        return httpx.Response(400, json={"error": {"message": "prompt is too long"}})

    provider = OpenAICompatibleProvider("http://llm/v1", "m", transport=httpx.MockTransport(handler))
    with pytest.raises(ProviderError) as info:
        provider.complete(ChatRequest(messages=[]))
    assert info.value.code == "context_too_long"

    def refuse(request):
        raise httpx.ConnectError("refused")

    provider = OpenAICompatibleProvider("http://llm/v1", "m", transport=httpx.MockTransport(refuse))
    with pytest.raises(ProviderError) as info:
        provider.complete(ChatRequest(messages=[]))
    assert info.value.code == "model_unavailable"


def test_cloud_run_sends_a_google_id_token_for_the_service():
    seen: list[httpx.Request] = []
    audiences: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        body = f"data: {chunk('Hi')}\n\ndata: [DONE]\n\n"
        return httpx.Response(200, text=body, headers={"content-type": "text/event-stream"})

    def token(audience: str) -> str:
        audiences.append(audience)
        return "id-token-123"

    provider = CloudRunProvider(
        "https://qwen-123.us-central1.run.app/v1",
        "Qwen/Qwen3-VL-8B-Instruct-FP8",
        transport=httpx.MockTransport(handler),
        token_source=token,
    )
    assert provider.complete(ChatRequest(messages=[{"role": "user", "content": "hi"}])).text == "Hi"
    assert audiences == ["https://qwen-123.us-central1.run.app"]  # the service URL, without /v1
    assert seen[0].headers["authorization"] == "Bearer id-token-123"
    assert str(seen[0].url) == "https://qwen-123.us-central1.run.app/v1/chat/completions"


def test_cloud_run_without_credentials_is_a_clear_error():
    def no_credentials(audience):
        raise RuntimeError("Your default credentials were not found")

    provider = CloudRunProvider("https://x.run.app/v1", "m", token_source=no_credentials)
    with pytest.raises(ProviderError) as info:
        provider.complete(ChatRequest(messages=[]))
    assert info.value.code == "model_unavailable"
    assert "GOOGLE_IMPERSONATE_SERVICE_ACCOUNT" in info.value.message


def test_service_root():
    assert service_root("https://x-1.us-central1.run.app/v1") == "https://x-1.us-central1.run.app"
    assert service_root("https://x-1.us-central1.run.app/v1/") == "https://x-1.us-central1.run.app"
    assert service_root("https://x-1.us-central1.run.app") == "https://x-1.us-central1.run.app"


def test_api_key_can_come_from_the_environment(monkeypatch):
    from apps.llm.providers import resolve_secret

    monkeypatch.setenv("OPENAI_KEY", "sk-from-env")
    assert resolve_secret("env:OPENAI_KEY") == "sk-from-env"
    assert resolve_secret("plain") == "plain"
    assert resolve_secret("env:MISSING") == ""
