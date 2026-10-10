"""Google ID tokens: the key to a private Cloud Run service.

A model service is deployed with "require authentication": Cloud Run itself
refuses any request without a valid Google ID token, signed by Google for an
identity that has roles/run.invoker on that service, and issued for that
service's URL (the "audience"). There is no API key to leak.

Where the token comes from:

* On Cloud Run, the api runs as its own service account. The metadata server
  hands out ID tokens for it: google.oauth2.id_token.fetch_id_token().
* On your laptop (the local app talking to a model on Cloud Run), your own
  Google login can't mint tokens for an audience, so it borrows a service
  account: set GOOGLE_IMPERSONATE_SERVICE_ACCOUNT, and your account needs
  roles/iam.serviceAccountTokenCreator on it (ml/cloudrun/deploy.py grants it).

Tokens last an hour; they are cached until 5 minutes before they expire.
"""

from __future__ import annotations

import os
import threading
import time

_cache: dict[str, tuple[str, float]] = {}
_lock = threading.Lock()
REFRESH_BEFORE_SECONDS = 300
SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]


def id_token(audience: str) -> str:
    """An ID token for `audience` (a Cloud Run service URL, e.g. https://x-123.us-central1.run.app)."""
    with _lock:
        cached = _cache.get(audience)
        if cached and cached[1] - REFRESH_BEFORE_SECONDS > time.time():
            return cached[0]
    token, expires_at = _fetch(audience)
    with _lock:
        _cache[audience] = (token, expires_at)
    return token


def _fetch(audience: str) -> tuple[str, float]:
    import google.auth
    from google.auth import impersonated_credentials, jwt
    from google.auth.transport.requests import Request
    from google.oauth2 import id_token as google_id_token

    request = Request()
    target = os.environ.get("GOOGLE_IMPERSONATE_SERVICE_ACCOUNT", "")
    if target:
        source, _project = google.auth.default(scopes=SCOPES)
        borrowed = impersonated_credentials.Credentials(
            source_credentials=source, target_principal=target, target_scopes=SCOPES, lifetime=3600
        )
        credentials = impersonated_credentials.IDTokenCredentials(
            borrowed, target_audience=audience, include_email=True
        )
        credentials.refresh(request)
        token = credentials.token
    else:
        token = google_id_token.fetch_id_token(request, audience)
    claims = jwt.decode(token, verify=False)  # only to read the expiry; Cloud Run verifies it
    return token, float(claims.get("exp", time.time() + 3000))
