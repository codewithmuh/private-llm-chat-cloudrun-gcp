# Secret Manager. The containers get these as environment variables, read
# when an instance starts; they never appear in the service configuration.
#
# Terraform generates the passwords, so nobody ever types or sees them. They
# are also in the Terraform state: keep the state private (a local file, or
# the private bucket from scripts/bootstrap-state.sh).

resource "random_password" "django_secret_key" {
  length  = 50
  special = false
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "searxng" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "django_secret_key" {
  secret_id = "${local.name}-django-secret-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "django_secret_key" {
  secret      = google_secret_manager_secret.django_secret_key.id
  secret_data = random_password.django_secret_key.result
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${local.name}-db-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "google_secret_manager_secret" "searxng" {
  count     = var.enable_web_search ? 1 : 0
  secret_id = "${local.name}-searxng-secret"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "searxng" {
  count       = var.enable_web_search ? 1 : 0
  secret      = google_secret_manager_secret.searxng[0].id
  secret_data = random_password.searxng.result
}

resource "google_secret_manager_secret" "smtp_password" {
  count     = var.email_provider == "smtp" ? 1 : 0
  secret_id = "${local.name}-smtp-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "smtp_password" {
  count = var.email_provider == "smtp" ? 1 : 0
  # Secret Manager refuses an empty secret; a provider without a password gets a placeholder it won't use.
  secret      = google_secret_manager_secret.smtp_password[0].id
  secret_data = var.smtp_password != "" ? var.smtp_password : "unused"
}

# The api reads all of them.
locals {
  api_secrets = merge(
    {
      django_secret_key = google_secret_manager_secret.django_secret_key.secret_id
      db_password       = google_secret_manager_secret.db_password.secret_id
    },
    var.enable_web_search ? { searxng = google_secret_manager_secret.searxng[0].secret_id } : {},
    var.email_provider == "smtp" ? { smtp_password = google_secret_manager_secret.smtp_password[0].secret_id } : {},
  )
}

resource "google_secret_manager_secret_iam_member" "api" {
  for_each  = local.api_secrets
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.api.member
}
