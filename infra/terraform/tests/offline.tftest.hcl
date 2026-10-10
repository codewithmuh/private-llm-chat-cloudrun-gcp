# Offline tests for the wiring of this stack.
#
#   ./scripts/terraform.sh init -backend=false
#   ./scripts/terraform.sh test
#
# The google provider is MOCKED: no Google account, no credentials, nothing is
# created and nothing is billed. What it checks is our own logic: the URLs the
# services use to find each other, the environment the containers get, the
# LLM_MODELS JSON, the GPU services built from ml/models/catalog.json, and the
# validation rules.

mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
  mock_resource "google_sql_database_instance" {
    defaults = { connection_name = "demo-proj-123:us-central1:llmchat-dev-db-abcd" }
  }
  # Valid-looking values: the provider still checks their format.
  mock_resource "google_service_account" {
    defaults = {
      email  = "mock-account@demo-proj-123.iam.gserviceaccount.com"
      member = "serviceAccount:mock-account@demo-proj-123.iam.gserviceaccount.com"
      name   = "projects/demo-proj-123/serviceAccounts/mock-account@demo-proj-123.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = { name = "projects/123456789012/locations/global/workloadIdentityPools/llmchat-dev-gh-abcd" }
  }
}

variables {
  project_id = "demo-proj-123"
}

run "default_stack" {
  command = apply

  assert {
    condition     = output.app_url == "https://llmchat-dev-web-123456789012.us-central1.run.app"
    error_message = "The web service's predicted URL is wrong: ${output.app_url}"
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_service.web.template[0].containers[0].env : e.value if e.name == "API_ORIGIN"]) == "https://llmchat-dev-api-123456789012.us-central1.run.app"
    error_message = "The web service must send /api/ to the api's URL."
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_service.api.template[0].containers[0].env : e.value if e.name == "ALLOWED_HOSTS"]) == "llmchat-dev-api-123456789012.us-central1.run.app"
    error_message = "ALLOWED_HOSTS must be the api's own host name (the web service calls that address)."
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_service.api.template[0].containers[0].env : e.value if e.name == "CSRF_TRUSTED_ORIGINS"]) == output.app_url
    error_message = "The browser's Origin is the web service: it must be trusted for CSRF."
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_service.api.template[0].containers[0].env : e.value if e.name == "DB_HOST"]) == "/cloudsql/demo-proj-123:us-central1:llmchat-dev-db-abcd"
    error_message = "The api must reach Cloud SQL through the /cloudsql/ socket."
  }

  assert {
    condition = jsondecode(one([for e in google_cloud_run_v2_service.api.template[0].containers[0].env : e.value if e.name == "LLM_MODELS"])) == [{
      id                = "qwen3-vl-8b"
      name              = "Qwen3-VL 8B (FP8)"
      description       = "Chat, vision and OCR in one model. The default: reads photos, screenshots, scans and charts."
      provider          = "cloudrun"
      base_url          = "https://llmchat-dev-qwen3-vl-8b-123456789012.us-central1.run.app/v1"
      model_id          = "Qwen/Qwen3-VL-8B-Instruct-FP8"
      vision            = true
      ocr               = true
      context_window    = 32768
      max_output_tokens = 4096
      temperature       = 0.7
      params            = { top_p = 0.8, top_k = 20, presence_penalty = 1.5 }
      hourly_cost_usd   = 1.42
      default           = true
      sort              = 10
    }]
    error_message = "LLM_MODELS for the default model is not what the api expects."
  }

  # Secrets come from Secret Manager, never as plain values.
  assert {
    condition     = length([for e in google_cloud_run_v2_service.api.template[0].containers[0].env : e.name if e.name == "DJANGO_SECRET_KEY" && e.value == null]) == 1
    error_message = "DJANGO_SECRET_KEY must come from Secret Manager."
  }

  # api + SearXNG + Whisper in one instance.
  assert {
    condition     = [for c in google_cloud_run_v2_service.api.template[0].containers : c.name] == ["api", "search", "speech"]
    error_message = "The api runs with the search and speech sidecars by default."
  }

  # The GPU service, from the catalog.
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-vl-8b"].name == "llmchat-dev-qwen3-vl-8b"
    error_message = "Model service name."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-vl-8b"].template[0].node_selector[0].accelerator == "nvidia-l4"
    error_message = "The default model runs on an L4."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-vl-8b"].template[0].containers[0].resources[0].limits == tomap({ cpu = "8", memory = "32Gi", "nvidia.com/gpu" = "1" })
    error_message = "CPU, memory and GPU of the default model."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-vl-8b"].template[0].scaling[0].min_instance_count == 0 && google_cloud_run_v2_service.model["qwen3-vl-8b"].template[0].scaling[0].max_instance_count == 1
    error_message = "Models scale between 0 (asleep) and 1 instance by default."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-vl-8b"].template[0].containers[0].args == tolist(["serve", "/models/Qwen/Qwen3-VL-8B-Instruct-FP8", "--served-model-name=Qwen/Qwen3-VL-8B-Instruct-FP8", "--host=0.0.0.0", "--port=8000", "--max-model-len=32768"])
    error_message = "vLLM's command line."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-vl-8b"].template[0].containers[0].image == "us-central1-docker.pkg.dev/demo-proj-123/llmchat-dev-dockerhub/vllm/vllm-openai:v0.30.0"
    error_message = "vLLM must come through the Docker Hub cache."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-vl-8b"].template[0].gpu_zonal_redundancy_disabled
    error_message = "No zonal redundancy: cheaper, and what the default quota covers."
  }
  assert {
    condition     = output.weights_to_stage == "Qwen/Qwen3-VL-8B-Instruct-FP8 false"
    error_message = "weights_to_stage: ${output.weights_to_stage}"
  }

  # Private services: the api only for the web, the models only for the api.
  assert {
    condition     = google_cloud_run_v2_service_iam_member.web_public.member == "allUsers" && google_cloud_run_v2_service_iam_member.web_calls_api.role == "roles/run.invoker"
    error_message = "Only the web service is public."
  }
}

run "several_models_and_overrides" {
  command = plan

  variables {
    models = {
      "llama-3.1-8b" = { preset = "llama-3.1-8b", min_instances = 1 }
      "qwen3-32b"    = { preset = "qwen3-32b" }
      "my-model" = {
        hf_model_id   = "my-org/my-model"
        gpu_type      = "nvidia-l4"
        cpu           = 4
        memory        = "16Gi"
        max_model_len = 8192
        vllm_args     = ["--enable-prefix-caching"]
        default       = true
      }
    }
  }

  assert {
    condition     = google_cloud_run_v2_service.model["llama-3.1-8b"].name == "llmchat-dev-llama-3-1-8b"
    error_message = "Dots in a model id become dashes in the service name."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["llama-3.1-8b"].template[0].scaling[0].min_instance_count == 1
    error_message = "min_instances = 1 keeps the GPU awake."
  }
  assert {
    condition     = google_cloud_run_v2_service.model["qwen3-32b"].launch_stage == "BETA" && google_cloud_run_v2_service.model["qwen3-32b"].template[0].node_selector[0].accelerator == "nvidia-rtx-pro-6000"
    error_message = "The RTX PRO 6000 is a preview (BETA) feature."
  }
  assert {
    condition     = contains(google_cloud_run_v2_service.model["qwen3-32b"].template[0].containers[0].args, "--reasoning-parser")
    error_message = "vllm_args from the catalog are passed on."
  }
  assert {
    condition     = contains(google_cloud_run_v2_service.model["my-model"].template[0].containers[0].args, "--enable-prefix-caching")
    error_message = "A model outside the catalog uses its own fields."
  }
  assert {
    condition     = output.weights_to_stage == "meta-llama/Llama-3.1-8B-Instruct true\nmy-org/my-model false\nQwen/Qwen3-32B-FP8 false"
    error_message = "weights_to_stage: ${output.weights_to_stage}"
  }
}

run "a_model_that_is_not_in_the_catalog_needs_its_fields" {
  command = plan

  variables {
    models = { "mystery" = { default = true } }
  }

  expect_failures = [google_cloud_run_v2_service.model]
}

run "smtp_without_search_or_speech" {
  command = plan

  variables {
    email_provider        = "smtp"
    smtp_host             = "smtp.example.com"
    smtp_username         = "apikey"
    smtp_password         = "not-a-real-password"
    from_email            = "Chat <chat@example.com>"
    enable_web_search     = false
    enable_speech_to_text = false
  }

  assert {
    condition     = length(google_cloud_run_v2_service.api.template[0].containers) == 1
    error_message = "Without search and speech, the api runs alone."
  }
  assert {
    condition     = one([for e in google_cloud_run_v2_service.api.template[0].containers[0].env : e.value if e.name == "EMAIL_HOST"]) == "smtp.example.com"
    error_message = "SMTP settings reach the api."
  }
  assert {
    condition     = length([for e in google_cloud_run_v2_service.api.template[0].containers[0].env : e.name if e.name == "WEB_SEARCH_URL" || e.name == "SPEECH_TO_TEXT_URL"]) == 0
    error_message = "No search or speech URLs when they are off."
  }
  assert {
    condition     = length(google_secret_manager_secret.smtp_password) == 1
    error_message = "The SMTP password goes to Secret Manager."
  }
}

run "github_actions" {
  command = plan

  variables {
    github_repository = "someone/private-llm-chat-cloudrun-gcp"
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github[0].attribute_condition == "assertion.repository == 'someone/private-llm-chat-cloudrun-gcp'"
    error_message = "Only this repository's workflows may deploy."
  }
  assert {
    condition     = length(google_project_iam_member.deploy_owner) == 0
    error_message = "By default GitHub may only push images."
  }
}

run "bad_settings_are_refused" {
  command = plan

  variables {
    project_id = "My_Project"
    models     = { "x" = { preset = "qwen3-vl-4b", min_instances = 2, max_instances = 1 } }
  }

  expect_failures = [var.project_id, var.models]
}
