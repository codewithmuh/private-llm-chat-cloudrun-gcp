# The app: two Cloud Run services.
#
#   web  Next.js. PUBLIC: the only address browsers use. It serves the pages
#        and passes /api/*, /admin/* and /django-static/* on to the api, so the
#        browser sees one origin and the login cookie just works
#        (frontend/src/lib/backend-proxy.ts).
#   api  Django. PRIVATE: only the web service may call it. Two more
#        containers run in the same instance ("sidecars"), reachable on
#        localhost: SearXNG (the Search button) and Whisper (the microphone).

locals {
  # The models, in the format of LLM_MODELS (docs/configuration.md). The api
  # loads them into its database at startup.
  llm_models = jsonencode([
    for i, id in sort(keys(local.models)) : {
      id                = id
      name              = local.models[id].name
      description       = local.models[id].description
      provider          = "cloudrun"
      base_url          = "${local.model_urls[id]}/v1"
      model_id          = local.models[id].hf_model_id
      vision            = local.models[id].vision
      ocr               = local.models[id].ocr
      context_window    = local.models[id].max_model_len
      max_output_tokens = 4096
      temperature       = local.models[id].temperature
      params            = local.models[id].params
      hourly_cost_usd   = local.models[id].hourly_usd
      default           = local.models[id].default
      sort              = (i + 1) * 10
    }
  ])

  api_env = merge(
    {
      DJANGO_SETTINGS_MODULE = "config.settings.production"
      RUN_BOOTSTRAP          = "true" # migrate + load LLM_MODELS at startup (a lock makes instances take turns)
      APP_NAME               = var.app_name
      PUBLIC_URL             = local.web_url
      CSRF_TRUSTED_ORIGINS   = local.web_url
      # Requests arrive with the api's own address as Host (from the web service).
      ALLOWED_HOSTS = trimprefix(local.api_url, "https://")
      LOG_FORMAT    = "json" # one JSON object per line: Cloud Logging shows the fields

      DB_HOST    = "/cloudsql/${google_sql_database_instance.main.connection_name}"
      DB_NAME    = google_sql_database.app.name
      DB_USER    = google_sql_user.app.name
      DB_SSLMODE = "disable" # a local unix socket; the Cloud SQL connection itself is encrypted

      STORAGE_BACKEND  = "gcs"
      GCS_BUCKET       = google_storage_bucket.uploads.name
      GCS_SIGNER_EMAIL = google_service_account.api.email

      EMAIL_PROVIDER     = var.email_provider
      EMAIL_VERIFICATION = var.email_verification
      DEFAULT_FROM_EMAIL = var.from_email != "" ? var.from_email : "${var.app_name} <no-reply@example.com>"
      SIGNUP_ENABLED     = tostring(var.signup_enabled)
      ADMIN_EMAILS       = join(",", var.admin_emails)
      GOOGLE_CLIENT_ID   = var.google_client_id

      LLM_MODELS = local.llm_models
    },
    var.email_provider == "smtp" ? {
      EMAIL_HOST      = var.smtp_host
      EMAIL_PORT      = tostring(var.smtp_port)
      EMAIL_HOST_USER = var.smtp_username
      EMAIL_USE_TLS   = "true"
    } : {},
    var.enable_web_search ? { WEB_SEARCH_URL = "http://localhost:${local.search_port}" } : {},
    var.enable_speech_to_text ? { SPEECH_TO_TEXT_URL = "http://localhost:${local.speech_port}" } : {},
  )

  api_secret_env = merge(
    {
      DJANGO_SECRET_KEY = google_secret_manager_secret.django_secret_key.secret_id
      DB_PASSWORD       = google_secret_manager_secret.db_password.secret_id
    },
    var.email_provider == "smtp" ? { EMAIL_HOST_PASSWORD = google_secret_manager_secret.smtp_password[0].secret_id } : {},
  )
}

# ===================================================================== api ===

resource "google_cloud_run_v2_service" "api" {
  name                = "${local.name}-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL" # reachable, but only with an ID token of the web service
  deletion_protection = false

  template {
    service_account                  = google_service_account.api.email
    max_instance_request_concurrency = 32      # gunicorn: 2 workers x 16 threads
    timeout                          = "3600s" # a chat answer streams for as long as it takes

    scaling {
      min_instance_count = var.api_min_instances
      max_instance_count = var.api_max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      name  = "api"
      image = local.images.api

      ports {
        container_port = local.api_port
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle          = true # CPU (and billing) only while handling requests
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = local.api_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.api_secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # The first start applies the database migrations: give it a few minutes.
      startup_probe {
        http_get {
          path = "/api/health/"
          port = local.api_port
        }
        period_seconds    = 5
        timeout_seconds   = 3
        failure_threshold = 60
      }
    }

    # SearXNG: the web search behind the chat's Search button.
    dynamic "containers" {
      for_each = var.enable_web_search ? [1] : []
      content {
        name  = "search"
        image = local.images.search
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
          cpu_idle = true
        }
        env {
          name = "SEARXNG_SECRET"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.searxng[0].secret_id
              version = "latest"
            }
          }
        }
        startup_probe {
          tcp_socket {
            port = local.search_port
          }
          period_seconds    = 5
          failure_threshold = 24
        }
      }
    }

    # Whisper: speech to text for the microphone button, on the CPU.
    dynamic "containers" {
      for_each = var.enable_speech_to_text ? [1] : []
      content {
        name  = "speech"
        image = local.images.speech
        resources {
          limits = {
            cpu    = "2"
            memory = "2Gi"
          }
          cpu_idle = true
        }
        env {
          name  = "WHISPER_THREADS"
          value = "2"
        }
        startup_probe {
          tcp_socket {
            port = local.speech_port
          }
          period_seconds    = 5
          failure_threshold = 24
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.api_sql,
    google_secret_manager_secret_iam_member.api,
    google_secret_manager_secret_version.django_secret_key,
    google_secret_manager_secret_version.db_password,
    google_secret_manager_secret_version.searxng,
    google_secret_manager_secret_version.smtp_password,
  ]
}

# Only the web service may call the api.
resource "google_cloud_run_v2_service_iam_member" "web_calls_api" {
  name     = google_cloud_run_v2_service.api.name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.web.member
}

# ===================================================================== web ===

resource "google_cloud_run_v2_service" "web" {
  name                = "${local.name}-web"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.web.email
    max_instance_request_concurrency = 80
    timeout                          = "3600s" # it passes the api's streamed answers through

    scaling {
      min_instance_count = var.web_min_instances
      max_instance_count = var.web_max_instances
    }

    containers {
      image = local.images.web

      ports {
        container_port = local.web_port
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      env {
        name  = "API_ORIGIN"
        value = local.api_url
      }
      env {
        name  = "API_AUTH" # send a Google ID token: the api is private
        value = "google-id-token"
      }
    }
  }
}

# Anyone may open the web service: it is the website. (The app itself asks
# people to sign in.)
resource "google_cloud_run_v2_service_iam_member" "web_public" {
  name     = google_cloud_run_v2_service.web.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}
