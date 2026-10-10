# Artifact Registry: where container images live.

# Our four images (api, web, search, speech). Cloud Build pushes them here
# (scripts/deploy.sh, or GitHub Actions); Cloud Run pulls them.
resource "google_artifact_registry_repository" "app" {
  repository_id = local.name
  location      = var.region
  format        = "DOCKER"
  description   = "Private LLM Chat images: api, web, search, speech"

  # Keep the last 10 versions of each image; older ones are deleted (storage
  # costs ~$0.10 per GB per month).
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }

  depends_on = [google_project_service.apis]
}

# A REMOTE repository: a cache of Docker Hub inside the project. Cloud Run
# pulls vLLM's ~10 GB image through it, so the image comes over Google's
# network, Docker Hub's download limits don't apply after the first pull,
# and an image Docker Hub deletes keeps working here.
resource "google_artifact_registry_repository" "dockerhub" {
  repository_id = "${local.name}-dockerhub"
  location      = var.region
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Docker Hub images (vLLM), cached for Cloud Run"

  remote_repository_config {
    description = "Docker Hub"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository_iam_member" "build_push" {
  repository = google_artifact_registry_repository.app.name
  location   = var.region
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.build.member
}
