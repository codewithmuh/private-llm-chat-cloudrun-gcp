# The models: one Cloud Run service with one GPU each, running vLLM.
#
# Each is PRIVATE (only the api's service account may call it) and scales to
# zero: no instance, and no bill, while nobody chats. The next message wakes
# it (1-3 minutes: start the container, load the weights onto the GPU); the
# app shows "Waking up the GPU" meanwhile. Cloud Run keeps an idle instance
# for up to ~15 minutes after the last request, then stops it.
#
# The weights must be in the weights bucket BEFORE a service is created
# (Cloud Run starts it once to check it works). scripts/deploy.sh copies them
# first: ml/cloudrun/deploy.py stage.

locals {
  catalog = jsondecode(file("${path.module}/../../ml/models/catalog.json")).presets

  # The catalog entry behind each model (null = not a preset: every field must be set).
  preset_of = { for id, m in var.models : id => try(local.catalog[coalesce(m.preset, id)], null) }

  models = {
    for id, m in var.models : id => {
      id      = id
      service = "${local.name}-${replace(id, ".", "-")}"
      default = m.default
      min     = m.min_instances
      max     = m.max_instances

      name          = m.name != null ? m.name : try(local.preset_of[id].name, id)
      description   = m.description != null ? m.description : try(local.preset_of[id].description, "")
      hf_model_id   = m.hf_model_id != null ? m.hf_model_id : try(local.preset_of[id].hf_model_id, null)
      gpu_type      = m.gpu_type != null ? m.gpu_type : try(local.preset_of[id].gpu_type, null)
      cpu           = m.cpu != null ? m.cpu : try(local.preset_of[id].cpu, null)
      memory        = m.memory != null ? m.memory : try(local.preset_of[id].memory, null)
      max_model_len = m.max_model_len != null ? m.max_model_len : try(local.preset_of[id].max_model_len, null)
      vllm_args     = m.vllm_args != null ? m.vllm_args : try(tolist(local.preset_of[id].vllm_args), [])
      temperature   = m.temperature != null ? m.temperature : try(local.preset_of[id].temperature, 0.7)
      params        = m.params != null ? m.params : try(tomap(local.preset_of[id].params), {})
      vision        = m.vision != null ? m.vision : try(local.preset_of[id].vision, false)
      ocr           = m.ocr != null ? m.ocr : try(local.preset_of[id].ocr, false)
      gated         = m.gated != null ? m.gated : try(local.preset_of[id].gated, false)
      hourly_usd    = m.hourly_usd != null ? m.hourly_usd : try(local.preset_of[id].hourly_usd, null)
    }
  }

  model_urls = { for id, m in local.models : id => "https://${m.service}-${local.run_domain}" }

  # vLLM's image, through the Docker Hub cache in registry.tf.
  vllm_image    = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dockerhub.repository_id}/${var.vllm_image}"
  weights_mount = "/models"
}

resource "google_cloud_run_v2_service" "model" {
  for_each = local.models

  name     = each.value.service
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL" # reachable, but every request needs an ID token (below)
  # The RTX PRO 6000 is a preview feature on Cloud Run.
  launch_stage        = each.value.gpu_type == "nvidia-rtx-pro-6000" ? "BETA" : null
  deletion_protection = false

  template {
    service_account                  = google_service_account.gpu.email
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    max_instance_request_concurrency = 32      # vLLM batches parallel requests on the one GPU
    timeout                          = "3600s" # wait for the GPU to wake, then stream an answer
    gpu_zonal_redundancy_disabled    = true    # cheaper, and what the default GPU quota covers

    scaling {
      min_instance_count = each.value.min # 0 = sleep when idle
      max_instance_count = each.value.max # each instance is one GPU (quota: 3 per region to start)
    }

    node_selector {
      accelerator = each.value.gpu_type
    }

    containers {
      image   = local.vllm_image
      command = ["vllm"]
      args = concat([
        "serve",
        "${local.weights_mount}/${each.value.hf_model_id}",
        "--served-model-name=${each.value.hf_model_id}", # the API name stays the Hugging Face id
        "--host=0.0.0.0",
        "--port=8000",
        "--max-model-len=${each.value.max_model_len}",
      ], each.value.vllm_args)

      ports {
        container_port = 8000
      }

      resources {
        limits = {
          cpu              = tostring(each.value.cpu)
          memory           = each.value.memory
          "nvidia.com/gpu" = "1"
        }
        cpu_idle          = false # GPUs need the CPU always on (instance-based billing)
        startup_cpu_boost = true
      }

      env {
        name  = "HF_HUB_OFFLINE" # everything it needs is in the bucket
        value = "1"
      }

      volume_mounts {
        name       = "weights"
        mount_path = local.weights_mount
      }

      # Ready only when vLLM's /health answers: loading the model onto the GPU
      # takes a minute or two. Up to 15 minutes before Cloud Run gives up.
      startup_probe {
        http_get {
          path = "/health"
          port = 8000
        }
        initial_delay_seconds = 0
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 90
      }
    }

    # The weights bucket, mounted read-only (Cloud Storage FUSE).
    volumes {
      name = "weights"
      gcs {
        bucket    = google_storage_bucket.weights.name
        read_only = true
      }
    }
  }

  lifecycle {
    precondition {
      condition     = each.value.hf_model_id != null && each.value.gpu_type != null && each.value.cpu != null && each.value.memory != null && each.value.max_model_len != null
      error_message = "Model ${each.key}: not a preset in ml/models/catalog.json, so set hf_model_id, gpu_type, cpu, memory and max_model_len (or set preset = \"<a preset>\")."
    }
  }

  depends_on = [google_storage_bucket_iam_member.gpu_weights]
}

# Only the api may call the models. Cloud Run checks the caller's Google ID
# token before vLLM sees the request: there is no API key to leak.
resource "google_cloud_run_v2_service_iam_member" "api_calls_model" {
  for_each = local.models

  name     = google_cloud_run_v2_service.model[each.key].name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.api.member
}
