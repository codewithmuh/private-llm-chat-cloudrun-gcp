# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]: the Google Cloud version

This repository was forked from the AWS version,
[private-llm-chat-sagemaker-aws](https://github.com/codewithmuh/private-llm-chat-sagemaker-aws),
and converted to Google Cloud. The app (chat, accounts and 2FA, files, OCR, web search,
voice input) is the same; where the models run and how it is deployed changed.

### Added
- Models on **Cloud Run GPUs**: one private Cloud Run service per model, running
  vLLM's official image (`vllm/vllm-openai`) on an NVIDIA L4 (24 GB) or, in preview,
  an RTX PRO 6000 (96 GB). New `cloudrun` provider: the OpenAI-compatible provider
  plus a Google ID token on every request (`backend/apps/llm/providers/cloudrun.py`,
  `google_auth.py`).
- **Scale to zero, and wake on message.** A model service has 0 to 1 instances, so
  its GPU costs nothing while nobody chats. A message to a sleeping model wakes it in
  the background (`backend/apps/llm/wake.py`): the api answers `503 model_starting`,
  the UI shows "Waking up the GPU" and retries. `POST /api/models/<id>/wake/` wakes
  one ahead of time; the admin has **Check now** and **Wake up now**.
  `min_instances = 1` keeps a model warm.
- `ml/cloudrun/deploy.py` (`make model-presets`, `model-deploy`, `model-chat`,
  `model-status`, `model-delete`): deploys one model with plain, printed `gcloud`
  commands (`--dry-run` prints them only). Cloud Build copies the weights from Hugging
  Face into a Cloud Storage bucket once; the service mounts them read-only with Cloud
  Storage FUSE. vLLM's image comes through an Artifact Registry remote repository (a
  cache of Docker Hub).
- `make up-cloud` (`docker-compose.cloudrun.yml`): the local app with models on Cloud
  Run GPUs. The api container borrows (impersonates) the `llmchat-invoker` service
  account with your own Google login to get ID tokens; no key files.
- **Same-origin web proxy.** The browser only talks to the web service, which forwards
  `/api/`, `/admin/` and `/django-static/` to the api (`frontend/src/lib/backend-proxy.ts`),
  streaming answers through. On Cloud Run the api is private: the web service calls it
  with an ID token in `X-Serverless-Authorization`. Locally too, the browser only
  uses http://localhost:3000.
- **Terraform for Google Cloud** (`infra/terraform`, flat files, one per topic): Cloud
  Run (web, api with SearXNG and Whisper as sidecars, one GPU service per model),
  Cloud SQL for PostgreSQL 17, Cloud Storage (uploads, weights, build sources),
  Secret Manager, Artifact Registry, service accounts with no keys, and optional
  Workload Identity Federation for GitHub Actions. Offline tests with a mocked Google
  provider (`./scripts/terraform.sh test`).
- **Cloud Build images** (`infra/cloudbuild/images.yaml`): `make deploy`
  (`scripts/deploy.sh`) builds the four images in Google Cloud (linux/amd64, also from
  an ARM Mac), copies the models' weights, then runs `terraform apply`.
- `gcloud` and Terraform run from their official Docker images (`scripts/gcloud.sh`,
  `scripts/terraform.sh`; `make gcp-login`, `make gcloud`, `make tf-init`/`tf-plan`/
  `tf-apply`/`tf-destroy`): nothing to install but Docker.
- Uploads in Cloud Storage with 5-minute signed links (`STORAGE_BACKEND=gcs`). Email
  through any SMTP provider, or written to the logs (`EMAIL_PROVIDER=console`).
- `.github/workflows/deploy.yml` (off by default): builds and pushes the images, and
  optionally runs Terraform, authenticated with Workload Identity Federation.

### Changed
- Model presets (`ml/models/catalog.json`) re-sized for Cloud Run GPUs: CPU, memory,
  GPU type, and approximate prices per hour while awake.
- `.env`: `GCP_PROJECT`, `GCP_REGION` and `HF_TOKEN` replace `AWS_PROFILE` and
  `AWS_REGION`. The local compose project is named `llmchat-gcp`, so it doesn't clash
  with the AWS version's containers and volumes.
- The docs describe Google Cloud: the guides 03 and 04 are now
  `docs/03-deploy-a-model-on-cloud-run.md` and
  `docs/04-deploy-the-full-stack-on-google-cloud.md`.

### Removed
- SageMaker: `ml/sagemaker/`, the `sagemaker` provider, endpoints and instance types.
- The GPU controller (`gpu_controller`, scaling modes `always_on`/`on_demand`/`off`/
  `manual`, `idle_minutes`): Cloud Run's scale to zero replaces it.
- `ml/vllm-router` (several models on one GPU).
- The AWS infrastructure: CloudFront, ALB, ECS Fargate, VPC, RDS, S3, SES, ECR,
  Secrets Manager, CloudWatch, IAM roles and OIDC to AWS. Also `docker-compose.aws.yml`,
  `make up-aws`, `scripts/gpu.sh` and `scripts/stage-weights.sh`.

## AWS version (history before the fork)

The entries below describe the AWS (SageMaker) version this repository was forked
from. They are kept as history; that version continues in
[private-llm-chat-sagemaker-aws](https://github.com/codewithmuh/private-llm-chat-sagemaker-aws).

### Added
- ChatGPT-style web app (Next.js): streaming answers, conversation history, model
  picker, file and image attachments, OCR tool, dark mode.
- Accounts: email + password, email verification, password reset, Sign in with Google,
  two-factor authentication (authenticator app or email codes) with recovery codes.
- Django REST backend with pluggable model providers: SageMaker, any OpenAI-compatible
  server (vLLM, Ollama, LM Studio...), and a mock for development.
- GPU controller: SageMaker endpoints start on demand and are deleted when idle.
- `ml/sagemaker/deploy.py`: deploy a model preset to SageMaker with AWS's vLLM container.
- `ml/vllm-router`: several models on one GPU behind one endpoint (advanced).
- Terraform for the full stack on AWS (CloudFront, ALB, ECS Fargate, RDS, S3, SES,
  SageMaker).
- Docker Compose for local development, with Mailpit and an optional Ollama profile.
- `make up` runs a real open-source model locally: the first time it asks which model
  (Qwen3-VL, Gemma 3, Llama 3.2, Qwen3...), downloads it, writes
  `config/models.local.json`, and checks that the model answers. `make model` switches
  models. It runs them on the GPU with Docker Model Runner (part of Docker Desktop; it
  asks before turning it on), else in Ollama in Docker (CPU).
- Web search: a **Search** button in the chat. The api looks the question up with
  SearXNG (`search/`, self-hosted, no API key; a compose service locally and a sidecar
  container in the api task on AWS, `enable_web_search`), reads the top pages, and
  the model answers from them with numbered citations and a sources list.
- Models can carry their recommended sampling settings (`params` in `LLM_MODELS`,
  editable in the admin); `make up` sets them for every menu model. The system prompt
  names the model, and without web search it tells the model to answer questions
  about the present once, with the year of its knowledge, instead of arguing with
  itself.
- Voice input: a microphone button in the chat. The browser records and converts
  to 16 kHz WAV; Whisper (`speech/`, whisper.cpp built from source, works on ARM)
  transcribes it in a container next to the api, locally and on AWS
  (`enable_speech_to_text`), so voice never leaves your infrastructure. The api
  task's default memory is now 2 GiB (api + SearXNG + Whisper).
- `docs/concepts.md`: every concept behind the project in one page, from tokens,
  model sizes, GPU memory and quantization to RAG, tool calling, Whisper, SageMaker
  and the app's architecture, with a pitch, design trade-offs and common questions.
- `RUN_LOCALLY.md`: a step-by-step guide for beginners, from installing Docker to chatting.

### Removed
- `make ollama` and `config/models.ollama.json`: replaced by `make up` / `make model`.
