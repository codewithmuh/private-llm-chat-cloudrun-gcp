# Service accounts: each part of the stack runs as its own identity, with only
# the permissions it needs. No keys are ever created: Cloud Run and Cloud
# Build hand each one short-lived credentials.
#
#   web    may call the api, nothing else
#   api    database, uploads bucket, secrets; may call the model services
#   gpu    what the model services run as: may read the weights bucket
#   build  what Cloud Build runs as: pushes images, copies model weights

resource "google_service_account" "web" {
  account_id   = "${local.name}-web"
  display_name = "LLM chat: the web service (Next.js)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "api" {
  account_id   = "${local.name}-api"
  display_name = "LLM chat: the api service (Django)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "gpu" {
  account_id   = "${local.name}-gpu"
  display_name = "LLM chat: the model services (vLLM on a GPU)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "build" {
  account_id   = "${local.name}-build"
  display_name = "LLM chat: Cloud Build (images, model weights)"
  depends_on   = [google_project_service.apis]
}

# ------------------------------------------------------------------ api ----

# Connect to Cloud SQL through Cloud Run's built-in connection (a unix socket).
resource "google_project_iam_member" "api_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.api.member
}

# Download links for uploads are "signed URLs". On Cloud Run there is no key
# file to sign with, so the api asks IAM to sign for it (signBlob), which
# needs this permission on its own account.
resource "google_service_account_iam_member" "api_signs_urls" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_service_account.api.member
}

# ---------------------------------------------------------------- build ----

resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.build.member
}
