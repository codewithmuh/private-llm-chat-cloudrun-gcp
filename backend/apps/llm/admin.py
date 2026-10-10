from django.contrib import admin, messages

from . import wake
from .models import LLMModel


@admin.register(LLMModel)
class LLMModelAdmin(admin.ModelAdmin):
    list_display = ("name", "slug", "provider", "status", "is_default", "enabled", "last_used_at")
    list_filter = ("provider", "enabled")
    search_fields = ("name", "slug", "model_id", "base_url")
    list_editable = ("enabled",)
    readonly_fields = (
        "managed_by_env",
        "last_used_at",
        "wake_requested_at",
        "awake_at",
        "last_error",
        "last_error_at",
        "created_at",
        "updated_at",
    )
    fieldsets = (
        (
            None,
            {
                "fields": (
                    "name",
                    "slug",
                    "description",
                    "provider",
                    "model_id",
                    "enabled",
                    "is_default",
                    "sort",
                    "managed_by_env",
                )
            },
        ),
        ("Server", {"fields": ("base_url", "api_key", "hourly_cost_usd")}),
        (
            "Capabilities",
            {"fields": ("vision", "ocr", "context_window", "max_output_tokens", "temperature", "params")},
        ),
        (
            "Cloud Run GPU state",
            {"fields": ("last_used_at", "wake_requested_at", "awake_at", "last_error", "last_error_at")},
        ),
    )
    actions = ["check_now", "wake_now"]

    @admin.display(description="Status")
    def status(self, obj: LLMModel) -> str:
        return obj.public_status()[0]

    @admin.action(description="Check now (asks the service's /health)")
    def check_now(self, request, queryset):
        for model in queryset.filter(provider=LLMModel.Provider.CLOUDRUN):
            awake = wake.check(model)
            self.message_user(request, f"{model.name}: {'awake' if awake else 'asleep or starting'}")

    @admin.action(description="Wake up now (Cloud Run models)")
    def wake_now(self, request, queryset):
        for model in queryset.filter(provider=LLMModel.Provider.CLOUDRUN):
            wake.start(model)
        self.message_user(request, "Waking up: about 1 to 3 minutes.", messages.SUCCESS)
