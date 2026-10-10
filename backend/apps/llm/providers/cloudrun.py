"""A model served by vLLM on a Cloud Run GPU (ml/cloudrun/, infra/terraform/models.tf).

vLLM speaks the OpenAI chat-completions API, so this is the OpenAI-compatible
provider plus one header: a Google ID token proving the api may call the
private service (google_auth.py).
"""

from __future__ import annotations

from collections.abc import Callable

import httpx

from .base import ProviderError
from .google_auth import id_token
from .openai_compat import OpenAICompatibleProvider


def service_root(base_url: str) -> str:
    """https://x-123.us-central1.run.app/v1 -> https://x-123.us-central1.run.app"""
    root = base_url.rstrip("/")
    return root[: -len("/v1")] if root.endswith("/v1") else root


class CloudRunProvider(OpenAICompatibleProvider):
    def __init__(
        self,
        base_url: str,
        model_id: str,
        transport: httpx.BaseTransport | None = None,
        token_source: Callable[[str], str] = id_token,
    ):
        super().__init__(base_url, model_id, api_key="", transport=transport)
        self.audience = service_root(base_url)
        self.token_source = token_source

    def _headers(self) -> dict:
        headers = super()._headers()
        try:
            headers["Authorization"] = f"Bearer {self.token_source(self.audience)}"
        except Exception as exc:  # noqa: BLE001 - google-auth raises several kinds
            raise ProviderError(
                f"Could not get a Google ID token to call the model service ({type(exc).__name__}). "
                "Locally, set GOOGLE_IMPERSONATE_SERVICE_ACCOUNT (docs/03).",
                "model_unavailable",
            ) from None
        return headers
