"""Health endpoint that answers before Host validation.

Cloud Run's startup and liveness probes call the container directly, with an
internal address as the Host header, which ALLOWED_HOSTS would reject with a
400: the service would never count as started. Listing internal addresses is
impractical and `*` would defeat the setting, so this middleware answers the
health path before host validation runs. It returns a fixed body and touches
no data; skipping host validation for it exposes nothing.
"""

from __future__ import annotations

from django.http import JsonResponse

HEALTH_PATHS = frozenset({"/api/health/", "/api/health"})


class HealthCheckMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.path in HEALTH_PATHS and request.method in ("GET", "HEAD"):
            return JsonResponse({"status": "ok"})
        return self.get_response(request)
