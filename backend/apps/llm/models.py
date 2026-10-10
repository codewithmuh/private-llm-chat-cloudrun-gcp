"""The model registry: which LLMs this deployment offers, and where they run.

Each row is one model people can pick in the UI. Rows come from the
`LLM_MODELS` environment variable (`manage.py sync_models`) or are added by
hand in /admin/.

A model on a Cloud Run GPU (provider "cloudrun") sleeps when nobody uses it:
Cloud Run scales its service down to zero instances, and the GPU costs nothing.
The first request wakes it (about 1-3 minutes: the instance starts in seconds,
then vLLM loads the weights). The row remembers when the service last answered,
so the UI can say "asleep" or "starting" (apps/llm/wake.py).
"""

from __future__ import annotations

from datetime import timedelta

from django.conf import settings
from django.db import models
from django.utils import timezone

# Cloud Run keeps an idle instance for up to ~15 minutes before scaling to
# zero. Assume the model is still awake for a little less than that.
AWAKE_FOR = timedelta(minutes=10)
# A wake that hasn't finished after this long has failed.
WAKE_GIVES_UP_AFTER = timedelta(minutes=10)


class LLMModel(models.Model):
    class Provider(models.TextChoices):
        CLOUDRUN = "cloudrun", "Cloud Run GPU service (vLLM, private)"
        OPENAI = "openai", "OpenAI-compatible server (vLLM, Ollama, Docker Model Runner, ...)"
        MOCK = "mock", "Mock (fake answers, for development)"

    slug = models.SlugField(max_length=100, unique=True, help_text="Id used by the API and UI.")
    name = models.CharField(max_length=100)
    description = models.CharField(max_length=300, blank=True)
    provider = models.CharField(max_length=20, choices=Provider.choices)
    model_id = models.CharField(
        max_length=200,
        blank=True,
        help_text='Sent as "model" in each request, e.g. Qwen/Qwen3-VL-8B-Instruct-FP8 or llama3.2:3b.',
    )

    # Where the server is. For cloudrun: https://<service>-<project number>.<region>.run.app/v1
    base_url = models.CharField(max_length=300, blank=True, help_text="e.g. http://ollama:11434/v1")
    api_key = models.CharField(max_length=300, blank=True, help_text="openai only. cloudrun uses Google ID tokens.")
    hourly_cost_usd = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True, help_text="What its GPU costs per hour while awake."
    )

    # Capabilities and limits
    vision = models.BooleanField(default=False, help_text="Accepts images directly.")
    ocr = models.BooleanField(default=False, help_text="Preferred model for the OCR tool.")
    context_window = models.PositiveIntegerField(default=8192)
    max_output_tokens = models.PositiveIntegerField(default=2048)
    temperature = models.FloatField(default=0.7)
    # Extra sampling settings sent with every chat request, as the model's
    # authors recommend them. presence_penalty is what keeps small models from
    # going round in circles ("Wait, correction: ...").
    params = models.JSONField(
        default=dict,
        blank=True,
        help_text='Sent with every chat request, e.g. {"top_p": 0.8, "top_k": 20, "presence_penalty": 1.5}.',
    )

    is_default = models.BooleanField(default=False)
    enabled = models.BooleanField(default=True)
    sort = models.IntegerField(default=100)
    managed_by_env = models.BooleanField(
        default=False,
        editable=False,
        help_text="Created from LLM_MODELS. sync_models overwrites its settings.",
    )

    # Runtime state of a cloudrun model (apps/llm/wake.py)
    last_used_at = models.DateTimeField(null=True, blank=True)
    wake_requested_at = models.DateTimeField(null=True, blank=True)
    awake_at = models.DateTimeField(null=True, blank=True, help_text="Last time the service answered.")
    last_error = models.CharField(max_length=500, blank=True)
    last_error_at = models.DateTimeField(null=True, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["sort", "name"]
        verbose_name = "LLM model"

    def __str__(self) -> str:
        return self.name

    # ------------------------------------------------------------ status ----

    @property
    def is_cloudrun(self) -> bool:
        return self.provider == self.Provider.CLOUDRUN

    def probably_awake(self) -> bool:
        """It answered recently, so Cloud Run hasn't scaled it to zero yet."""
        if not self.awake_at:
            return False
        last_seen = max(self.awake_at, self.last_used_at or self.awake_at)
        return timezone.now() - last_seen < AWAKE_FOR

    def waking(self) -> bool:
        if not self.wake_requested_at:
            return False
        return timezone.now() - self.wake_requested_at < WAKE_GIVES_UP_AFTER

    def public_status(self) -> tuple[str, str]:
        """(status, detail) as shown in the UI. See docs/api.md."""
        if not self.is_cloudrun:
            return "ready", ""
        minutes = max(1, round(settings.MODEL_WAKE_SECONDS / 60))
        if self.probably_awake():
            return "ready", ""
        if self.waking():
            return "starting", f"Waking up the GPU. This usually takes about {minutes} minutes."
        if self.last_error and self.last_error_at and timezone.now() - self.last_error_at < WAKE_GIVES_UP_AFTER:
            return "failed", f"The GPU did not start: {self.last_error}"
        return "stopped", f"Asleep to save money. Your first message wakes it up (about {minutes} minutes)."

    def touch(self) -> None:
        """Record use (a recently used model is assumed to still be awake)."""
        now = timezone.now()
        LLMModel.objects.filter(pk=self.pk).update(last_used_at=now)
        self.last_used_at = now

    def as_api(self) -> dict:
        status, detail = self.public_status()
        return {
            "id": self.slug,
            "name": self.name,
            "description": self.description,
            "provider": self.provider,
            "vision": self.vision,
            "ocr": self.ocr,
            "context_window": self.context_window,
            "is_default": self.is_default,
            "status": status,
            "status_detail": detail,
        }

    @classmethod
    def default_for(cls, user=None) -> LLMModel | None:
        enabled = cls.objects.filter(enabled=True)
        if user is not None and getattr(user, "default_model", ""):
            chosen = enabled.filter(slug=user.default_model).first()
            if chosen:
                return chosen
        return enabled.filter(is_default=True).first() or enabled.first()
