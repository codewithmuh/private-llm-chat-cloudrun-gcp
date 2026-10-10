"""GET /api/models/ and POST /api/models/{id}/wake/ (docs/api.md, "Models")."""

from __future__ import annotations

from rest_framework import status
from rest_framework.decorators import api_view
from rest_framework.request import Request
from rest_framework.response import Response

from . import wake
from .models import LLMModel
from .services import get_model


@api_view(["GET"])
def model_list(request: Request) -> Response:
    models = list(LLMModel.objects.filter(enabled=True))
    for model in models:
        wake.refresh(model)  # a model that is waking up: is it ready yet?
    return Response([m.as_api() for m in models])


@api_view(["POST"])
def model_wake(request: Request, slug: str) -> Response:
    model = get_model(slug)
    model.touch()
    if model.is_cloudrun and not model.probably_awake():
        wake.start(model)
    state, detail = model.public_status()
    return Response({"status": state, "status_detail": detail}, status=status.HTTP_202_ACCEPTED)
