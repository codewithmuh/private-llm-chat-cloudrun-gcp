"""Sending email: one small helper.

`send_email("verify_email", to, context)` renders
templates/emails/verify_email.txt (first line = subject) and sends it with
whatever EMAIL_BACKEND is configured (EMAIL_PROVIDER):

- console (default)  prints the email to the logs. On Cloud Run that means
                     Cloud Logging: you can read a sign-up code there before
                     setting up real email.
- smtp               any SMTP server: Mailpit in docker compose
                     (http://localhost:8025), or a provider such as SendGrid,
                     Brevo or Gmail in production. Google Cloud has no email
                     sending service of its own.
"""

from __future__ import annotations

import logging

from django.conf import settings
from django.core.mail import send_mail
from django.template.loader import render_to_string

log = logging.getLogger(__name__)


def send_email(template: str, to: str, context: dict | None = None) -> None:
    ctx = {"app_name": settings.APP_NAME, "public_url": settings.PUBLIC_URL, **(context or {})}
    rendered = render_to_string(f"emails/{template}.txt", ctx).strip()
    subject, _, body = rendered.partition("\n")
    send_mail(
        subject=subject.strip(),
        message=body.strip() + "\n",
        from_email=settings.DEFAULT_FROM_EMAIL,
        recipient_list=[to],
        fail_silently=False,
    )
    # The template name only: never the code or the address.
    log.info("email sent", extra={"template": template})
