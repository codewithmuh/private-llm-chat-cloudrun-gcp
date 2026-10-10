# Cloud Storage buckets. Bucket names are global; starting them with the
# project ID keeps them unique.

# Files users attach to chats. Private: uploads go through the api, and
# downloads are 5-minute signed links (backend/apps/files/views.py).
resource "google_storage_bucket" "uploads" {
  name                        = "${var.project_id}-${local.name}-uploads"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # dev: `terraform destroy` deletes the files too. prod: it refuses while files exist.
  force_destroy = !local.is_prod

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "api_uploads" {
  bucket = google_storage_bucket.uploads.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.api.member
}

# The models' weights, copied once from Hugging Face by Cloud Build
# (ml/cloudrun/deploy.py stage). Each model service mounts this bucket
# read-only, so a waking GPU reads ~10 GB from the same region instead of
# downloading it from the internet again.
resource "google_storage_bucket" "weights" {
  name                        = "${var.project_id}-${local.name}-weights"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # A copy of public files: always safe to delete with the stack.
  force_destroy = true

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "gpu_weights" {
  bucket = google_storage_bucket.weights.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.gpu.member
}

resource "google_storage_bucket_iam_member" "build_weights" {
  bucket = google_storage_bucket.weights.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.build.member
}

# `gcloud builds submit` uploads the source code here (a .tgz) for Cloud Build
# to read. Old uploads are deleted after a week.
resource "google_storage_bucket" "build_source" {
  name                        = "${var.project_id}-${local.name}-build-source"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "build_source" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.build.member
}
