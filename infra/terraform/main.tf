# Private LLM Chat on Google Cloud: the whole stack.
#
#   browser --HTTPS--> Cloud Run "web" (Next.js: the pages, and /api/*, /admin/*,
#                      |                /django-static/* passed on to the api)
#                      '--ID token--> Cloud Run "api" (Django, private)
#                                       + sidecars: SearXNG (web search), Whisper (speech)
#   api --> Cloud SQL PostgreSQL, Cloud Storage (uploads), Secret Manager
#   api --ID token--> Cloud Run GPU services, one per model (vLLM, private, 0-1 instances)
#                     reading the weights from Cloud Storage
#
# The files, in reading order:
#   main.tf      names, the project, the Google APIs to turn on
#   identity.tf  service accounts: who each part runs as, and what it may do
#   registry.tf  Artifact Registry: our images, and a cache of Docker Hub (vLLM)
#   storage.tf   Cloud Storage: uploads, model weights, build sources
#   secrets.tf   Secret Manager: Django's key, the database password, ...
#   database.tf  Cloud SQL for PostgreSQL
#   models.tf    the GPU services (vLLM)
#   app.tf       the web and api services
#   github.tf    optional: deploys from GitHub Actions without keys
#   outputs.tf   the app's URL and what scripts/deploy.sh needs

locals {
  name    = "${var.app}-${var.environment}"
  is_prod = var.environment == "prod"

  labels = {
    app         = var.app
    environment = var.environment
    managed-by  = "terraform"
  }

  # Cloud Run gives every service a predictable address:
  #   https://<service>-<project number>.<region>.run.app
  # Knowing them in advance lets the web service point at the api, and the api
  # name the web's address (for CSRF and links in emails), without a cycle.
  run_domain = "${data.google_project.this.number}.${var.region}.run.app"
  web_url    = "https://${local.name}-web-${local.run_domain}"
  api_url    = "https://${local.name}-api-${local.run_domain}"

  # Container ports. They must match the Dockerfiles.
  api_port    = 8000
  web_port    = 3000
  search_port = 8080 # search/Dockerfile (SearXNG)
  speech_port = 9000 # speech/Dockerfile (whisper.cpp)

  images = {
    for name in ["api", "web", "search", "speech"] :
    name => "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}/${name}:${var.image_tag}"
  }
}

data "google_project" "this" {
  project_id = var.project_id
}

# A short random suffix for names Google won't let you reuse soon after a
# delete (Cloud SQL instances: a week; identity pools: 30 days), so destroy +
# apply works.
resource "random_id" "suffix" {
  byte_length = 2
}

# =========================================================== Google APIs =====
# A new project has most services switched off. Turning them on is free.

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "sts.googleapis.com", # Workload Identity Federation (GitHub Actions)
  ])

  service = each.value
  # Leave them on at `terraform destroy`: other things in the project may use them.
  disable_on_destroy = false
}

# ============================================================ foundation =====
# scripts/deploy.sh applies this first, with -target: everything Cloud Build
# needs before the images and the model weights exist. Terraform then creates
# the services, which need both.

resource "terraform_data" "foundation" {
  input = {
    registry       = google_artifact_registry_repository.app.id
    dockerhub      = google_artifact_registry_repository.dockerhub.id
    weights_bucket = google_storage_bucket.weights.name
    source_bucket  = google_storage_bucket.build_source.name
    builder        = google_service_account.build.email
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.build_push,
    google_storage_bucket_iam_member.build_weights,
    google_storage_bucket_iam_member.build_source,
    google_project_iam_member.build_logs,
  ]
}

check "smtp_settings" {
  assert {
    condition     = var.email_provider != "smtp" || (var.smtp_host != "" && var.from_email != "")
    error_message = "email_provider = \"smtp\" needs smtp_host and from_email (and usually smtp_username / smtp_password)."
  }
}
