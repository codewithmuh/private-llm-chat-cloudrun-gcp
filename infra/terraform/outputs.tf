output "app_url" {
  description = "Open this in your browser."
  value       = local.web_url
}

output "api_url" {
  description = "The api service. Private: it answers only the web service."
  value       = local.api_url
}

output "models" {
  description = "The model services: address, GPU, and price per hour while awake."
  value = {
    for id, m in local.models : id => {
      service    = m.service
      url        = local.model_urls[id]
      model      = m.hf_model_id
      gpu        = m.gpu_type
      hourly_usd = m.hourly_usd
      instances  = "${m.min}-${m.max}"
    }
  }
}

output "registry" {
  description = "Where the images go: <registry>/api:<tag> and so on."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

output "weights_bucket" {
  value = google_storage_bucket.weights.name
}

output "uploads_bucket" {
  value = google_storage_bucket.uploads.name
}

output "build_source_bucket" {
  value = google_storage_bucket.build_source.name
}

output "build_service_account" {
  value = google_service_account.build.email
}

output "database_instance" {
  description = "Cloud SQL instance connection name (project:region:instance)."
  value       = google_sql_database_instance.main.connection_name
}

# One line per model: "<hugging face id> <gated true/false>". scripts/deploy.sh
# copies each one's weights before the services are created.
output "weights_to_stage" {
  value = join("\n", [for id in sort(keys(local.models)) : "${coalesce(local.models[id].hf_model_id, "(no hf_model_id)")} ${local.models[id].gated}"])
}

output "github_workload_identity_provider" {
  description = "Repository variable GCP_WORKLOAD_IDENTITY_PROVIDER (.github/workflows/deploy.yml)."
  value       = local.github ? google_iam_workload_identity_pool_provider.github[0].name : null
}

output "github_deploy_service_account" {
  description = "Repository variable GCP_DEPLOY_SERVICE_ACCOUNT (.github/workflows/deploy.yml)."
  value       = local.github ? google_service_account.deploy[0].email : null
}
