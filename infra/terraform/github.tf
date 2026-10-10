# OPTIONAL: let GitHub Actions deploy (.github/workflows/deploy.yml), without
# any key. Set github_repository = "owner/repo" to turn it on.
#
# How it works (Workload Identity Federation): every GitHub Actions run gets
# a signed token from GitHub saying which repository it runs for. Google
# trusts GitHub's tokens for THIS repository only (attribute_condition), and
# swaps one for short-lived credentials of the deploy service account.
#
# By default the deploy account may only push images. With
# github_terraform_apply = true it is a project Owner, because `terraform
# apply` creates service accounts, IAM bindings, databases... Only turn that
# on for a repository whose main branch you control.

locals {
  github = var.github_repository != ""
}

resource "google_iam_workload_identity_pool" "github" {
  count                     = local.github ? 1 : 0
  workload_identity_pool_id = "${local.name}-gh-${random_id.suffix.hex}"
  display_name              = "GitHub Actions"
  description               = "Deploys from ${var.github_repository}"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count                              = local.github ? 1 : 0
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }
  # Only tokens from this one repository are accepted.
  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "deploy" {
  count        = local.github ? 1 : 0
  account_id   = "${local.name}-deploy"
  display_name = "LLM chat: GitHub Actions deploys"
  depends_on   = [google_project_service.apis]
}

# The repository's workflows may act as the deploy account.
resource "google_service_account_iam_member" "github_acts_as_deploy" {
  count              = local.github ? 1 : 0
  service_account_id = google_service_account.deploy[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github_repository}"
}

# Push images.
resource "google_artifact_registry_repository_iam_member" "deploy_push" {
  count      = local.github ? 1 : 0
  repository = google_artifact_registry_repository.app.name
  location   = var.region
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.deploy[0].member
}

# Run terraform apply (and copy new models' weights with Cloud Build).
resource "google_project_iam_member" "deploy_owner" {
  count   = var.github_terraform_apply ? 1 : 0
  project = var.project_id
  role    = "roles/owner"
  member  = google_service_account.deploy[0].member
}
