"""Production (Google Cloud Run). Fails fast when required configuration is missing.

Traffic path: browser -> web service (Next.js, HTTPS) -> api service (Django).
The web service forwards /api/, /admin/ and /django-static/ to this one
(frontend/src/lib/backend-proxy.ts), so the browser sees one origin and the
session cookie needs no cross-site settings. Cloud Run terminates TLS in front
of each service and tells Django the original scheme in X-Forwarded-Proto.
"""

import os

from .base import *  # noqa: F403
from .base import env, env_int

DEBUG = False

_missing = [name for name in ("DJANGO_SECRET_KEY",) if not os.environ.get(name)]
if _missing:
    raise RuntimeError(f"Missing required environment variables: {', '.join(_missing)}")

SECURE_PROXY_SSL_HEADER = (env("PROXY_SSL_HEADER", "HTTP_X_FORWARDED_PROTO"), "https")
# Cloud Run only serves HTTPS to browsers already; a redirect here would also
# hit its plain-HTTP health checks.
SECURE_SSL_REDIRECT = False
SECURE_HSTS_SECONDS = env_int("SECURE_HSTS_SECONDS", 60 * 60 * 24 * 365)
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_REFERRER_POLICY = "strict-origin-when-cross-origin"
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
X_FRAME_OPTIONS = "DENY"

# The web service and Cloud Run's front end both sit in front of Django.
REST_FRAMEWORK["NUM_PROXIES"] = env_int("NUM_PROXIES", 2)  # noqa: F405

LOGGING["handlers"]["console"]["formatter"] = env("LOG_FORMAT", "json")  # noqa: F405
