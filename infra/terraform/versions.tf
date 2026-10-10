# Terraform and provider versions.
#
# The lock file next to this one (.terraform.lock.hcl) pins the exact provider
# builds that were tested. Commit it: it makes `terraform init` on another
# machine download exactly the same providers.

terraform {
  # 1.9 is the minimum because variables.tf uses validation rules that look at
  # more than one variable (added in Terraform 1.9). scripts/terraform.sh runs
  # a newer one from Docker.
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Tested with 8.6.0. Cloud Run GPUs (node_selector, gpu_zonal_redundancy_disabled)
      # and Cloud Storage volumes are in the regular provider, not google-beta.
      version = "~> 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # No `backend` block here on purpose: by default the state is a LOCAL file
  # (terraform.tfstate in this folder). That is the simplest start. To keep the
  # state in Cloud Storage instead (needed for the GitHub Actions deploy), see
  # backend.tf.example and scripts/bootstrap-state.sh.
}

# Credentials are NOT configured here. The provider uses "application default
# credentials": the login `make gcp-login` saved in ~/.config/gcloud
# (scripts/terraform.sh passes it into the container). In GitHub Actions,
# Workload Identity Federation provides them. Never put a key file in this
# repository.
provider "google" {
  project = var.project_id
  region  = var.region

  # Every resource that supports labels gets these, which makes the stack easy
  # to find in the console and in billing reports (Billing -> Reports ->
  # filter by label app=llmchat).
  default_labels = local.labels
}
