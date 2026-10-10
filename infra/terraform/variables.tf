# Every setting of the stack. Only project_id has no default.
# Set them in terraform.tfvars (copy terraform.tfvars.example).

# =============================================================== basics =====

variable "project_id" {
  description = "Your Google Cloud project ID (not its name or number), e.g. my-llm-chat-123."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id is the project ID: 6-30 lowercase letters, digits and dashes, e.g. my-llm-chat-123."
  }
}

variable "region" {
  description = "Region for everything. It must have Cloud Run GPUs: us-central1, us-east4, europe-west1, europe-west4, asia-southeast1 (L4)."
  type        = string
  default     = "us-central1"
}

variable "app" {
  description = "Short name: the start of every resource name."
  type        = string
  default     = "llmchat"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.app))
    error_message = "app: 2-12 lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "environment" {
  description = "dev, staging or prod. prod turns on deletion protection for the database and the uploads."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "image_tag" {
  description = "Tag of the api, web, search and speech images to run. scripts/deploy.sh sets it (image.auto.tfvars)."
  type        = string
  default     = "latest"
}

# =============================================================== models =====

variable "models" {
  description = <<-EOT
    The models to deploy, one Cloud Run GPU service each. The key is the model's
    id in the app. `preset` is a name from ml/models/catalog.json, which fills in
    everything else; any field set here overrides the preset. A model that is
    not in the catalog needs hf_model_id, gpu_type, cpu, memory and max_model_len.
    min_instances = 1 keeps the GPU awake all the time (billed 24/7).
  EOT
  type = map(object({
    preset        = optional(string)
    default       = optional(bool, false)
    min_instances = optional(number, 0)
    max_instances = optional(number, 1)

    name          = optional(string)
    description   = optional(string)
    hf_model_id   = optional(string)
    gpu_type      = optional(string)
    cpu           = optional(number)
    memory        = optional(string)
    max_model_len = optional(number)
    vllm_args     = optional(list(string))
    temperature   = optional(number)
    params        = optional(map(number))
    vision        = optional(bool)
    ocr           = optional(bool)
    gated         = optional(bool)
    hourly_usd    = optional(number)
  }))
  default = {
    "qwen3-vl-8b" = { preset = "qwen3-vl-8b", default = true }
  }

  validation {
    condition     = length(var.models) > 0
    error_message = "Deploy at least one model."
  }

  validation {
    condition     = alltrue([for m in values(var.models) : m.min_instances >= 0 && m.max_instances >= 1 && m.min_instances <= m.max_instances])
    error_message = "For each model: 0 <= min_instances <= max_instances, and max_instances >= 1."
  }

  validation {
    condition     = alltrue([for m in values(var.models) : m.gpu_type == null || contains(["nvidia-l4", "nvidia-rtx-pro-6000"], coalesce(m.gpu_type, "x"))])
    error_message = "gpu_type is nvidia-l4 or nvidia-rtx-pro-6000."
  }

  validation {
    condition     = length([for k in keys(var.models) : k if can(regex("^[a-z0-9][a-z0-9.-]{0,30}$", k))]) == length(var.models)
    error_message = "Model ids (the keys): lowercase letters, digits, dots and dashes, up to 31 characters."
  }
}

variable "vllm_image" {
  description = "vLLM's image on Docker Hub, pulled through the Artifact Registry cache. Keep it the same as VLLM_IMAGE in ml/cloudrun/deploy.py."
  type        = string
  default     = "vllm/vllm-openai:v0.30.0"
}

# ============================================================ the app =====

variable "app_name" {
  description = "Name shown in the app and in emails."
  type        = string
  default     = "Private LLM Chat"
}

variable "admin_emails" {
  description = "These emails become admins (/admin/) once verified."
  type        = list(string)
  default     = []
}

variable "google_client_id" {
  description = "OAuth Web client id for \"Sign in with Google\" (docs/authentication.md). Empty = email + password only."
  type        = string
  default     = ""
}

variable "signup_enabled" {
  description = "false = nobody new can sign up (admins add users in /admin/)."
  type        = bool
  default     = true
}

variable "email_verification" {
  description = "mandatory, optional or none."
  type        = string
  default     = "mandatory"

  validation {
    condition     = contains(["mandatory", "optional", "none"], var.email_verification)
    error_message = "email_verification must be mandatory, optional or none."
  }
}

variable "enable_web_search" {
  description = "Run SearXNG next to the api for the chat's Search button."
  type        = bool
  default     = true
}

variable "enable_speech_to_text" {
  description = "Run Whisper next to the api for the microphone button."
  type        = bool
  default     = true
}

# =============================================================== email =====
# Google Cloud has no email-sending service. "console" writes every email
# (sign-up codes, password resets) to the api's logs in Cloud Logging, which is
# enough to try the app. For real users, use any SMTP provider.

variable "email_provider" {
  description = "console (emails go to Cloud Logging) or smtp."
  type        = string
  default     = "console"

  validation {
    condition     = contains(["console", "smtp"], var.email_provider)
    error_message = "email_provider must be console or smtp."
  }
}

variable "from_email" {
  description = "Sender address, e.g. \"Private LLM Chat <no-reply@example.com>\". Your SMTP provider must allow it."
  type        = string
  default     = ""
}

variable "smtp_host" {
  description = "e.g. smtp.sendgrid.net, smtp-relay.brevo.com, smtp.mailgun.org, smtp.gmail.com"
  type        = string
  default     = ""
}

variable "smtp_port" {
  type    = number
  default = 587
}

variable "smtp_username" {
  type    = string
  default = ""
}

variable "smtp_password" {
  description = "Stored in Secret Manager. It also ends up in the Terraform state: keep the state private."
  type        = string
  default     = ""
  sensitive   = true
}

# ============================================================ database =====

variable "db_tier" {
  description = "Cloud SQL machine type. db-f1-micro (shared core, ~$9/month) is plenty to learn and for a small team; db-custom-1-3840 for more."
  type        = string
  default     = "db-f1-micro"
}

variable "db_disk_gb" {
  type    = number
  default = 10
}

# ================================================================ scale =====

variable "api_min_instances" {
  description = "0 = the api sleeps when idle (the first request after a while takes a few seconds). 1 = always warm (~$10+/month more)."
  type        = number
  default     = 0
}

variable "api_max_instances" {
  type    = number
  default = 4
}

variable "web_min_instances" {
  type    = number
  default = 0
}

variable "web_max_instances" {
  type    = number
  default = 4
}

# =============================================================== GitHub =====

variable "github_repository" {
  description = "\"owner/repo\" lets that repository's GitHub Actions deploy, with Workload Identity Federation (no keys). Empty = off."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository is \"owner/repo\", e.g. codewithmuh/private-llm-chat-cloudrun-gcp."
  }
}

variable "github_terraform_apply" {
  description = "Also let GitHub Actions run terraform apply. This gives the deploy account Owner on the project."
  type        = bool
  default     = false

  validation {
    condition     = !var.github_terraform_apply || var.github_repository != ""
    error_message = "github_terraform_apply needs github_repository."
  }
}
