# Contributing

Thanks for helping! This project is meant to be **the place people learn to run
LLMs privately on Google Cloud**, so contributions that make it clearer are as welcome
as new features: a better explanation, a model preset you tested, a fix for a
confusing error message.

## Ways to help

- **Try it and report what confused you.** If a doc step failed, that's a bug.
- **Add a model preset** you actually deployed (see below).
- **Improve the docs**: typos, missing steps, screenshots, translations.
- **Pick an issue** labelled `good first issue` or `help wanted`.
- **Build a feature** from the [roadmap](docs/roadmap.md). Open an issue first for
  anything big, so we can agree on the approach before you spend a weekend on it.

## Project map

```
backend/            Django + Django REST Framework API
  config/           settings (base / dev / production / test), urls
  apps/accounts/    users, email verification, password reset, Google, 2FA
  apps/llm/         model registry, providers (cloudrun, openai, mock), waking
                    sleeping Cloud Run models (wake.py), Google ID tokens
  apps/chat/        conversations, prompt building, SSE streaming, titles, web search
  apps/files/       uploads, text extraction, OCR
  apps/speech/      speech to text (calls the Whisper container)
  apps/common/      errors, CSRF-aware auth, email, health check, throttles
  tests/            pytest suite (no network, no Google Cloud)
frontend/           Next.js (App Router, TypeScript) chat UI; forwards /api/ and
                    /admin/ to the api (src/lib/backend-proxy.ts)
ml/
  cloudrun/         deploy.py: deploy one model to a Cloud Run GPU (learning path)
  models/           catalog.json: tested model presets
  mock/             fake OpenAI-compatible model server
infra/terraform/    the full Google Cloud stack, one .tf file per topic
  tests/            offline Terraform tests (mocked Google provider)
infra/cloudbuild/   images.yaml: builds the four images in Google Cloud
search/, speech/    SearXNG and Whisper images (the Search and microphone buttons)
scripts/            up.sh, gcloud.sh, terraform.sh, deploy.sh, bootstrap-state.sh
config/             model lists for local development
docs/               guides and reference
```

## Development setup

**Docker is the only thing you must install.** Everything else runs from the
repository: the app with Docker Compose, and `gcloud` and Terraform from their
official Docker images through `scripts/gcloud.sh` and `scripts/terraform.sh`. Please
keep it that way: don't add steps that need `brew install`, a host `gcloud` or a host
`terraform`.

```bash
make up                 # everything in Docker: http://localhost:3000
make logs               # follow the api and web logs
make down               # stop (make reset also deletes the local data)
```

To work on one side with hot reload, you also need Python 3.12 and Node 22:

```bash
make backend-dev        # Django on :8000 with SQLite + the in-process mock model
make frontend-dev       # Next.js on :3000, passing /api/ and /admin/ on to :8000
```

Emails (verification codes, password resets) are printed in the backend's output with
`make backend-dev`, and appear in Mailpit (http://localhost:8025) with `make up`.

Working on the Cloud Run side? `make gcp-login` (once), then
`make model-deploy PRESET=...` and `make up-cloud` run the local app against a model
on a real Cloud Run GPU ([docs/03](docs/03-deploy-a-model-on-cloud-run.md)). That costs
money while the GPU is awake: `make model-delete` when you're done. To see what a
deploy would do without a Google account, print the commands:

```bash
./scripts/gcloud.sh --run python3 ml/cloudrun/deploy.py deploy qwen3-vl-8b --dry-run --project my-project
```

`make help` lists every target.

## Before you open a pull request

```bash
make lint               # ruff + eslint + tsc
make test               # pytest + frontend typecheck, lint and build
```

If you changed anything in `infra/terraform/`, also run the Terraform checks. They
run in Docker and need no Google account: the tests use a mocked Google provider.

```bash
./scripts/terraform.sh fmt -recursive
./scripts/terraform.sh init -backend=false   # once: downloads the Google provider
./scripts/terraform.sh validate
./scripts/terraform.sh test                  # infra/terraform/tests/offline.tftest.hcl
```

CI runs the same checks, plus a `--dry-run` model deploy and the Docker image builds.

- **Backend**: `ruff format` style (`make fmt`), type hints on new functions, a test
  for every bug fix and every new endpoint. Tests never touch the network: fake the
  provider (see `tests/test_providers.py`) or Google (see `tests/test_cloudrun.py` and
  `tests/test_google.py`).
- **Frontend**: TypeScript strict, no `any`. Keep components small. Plain CSS with
  the variables in `globals.css`.
- **Terraform**: `terraform fmt` (`make fmt` runs it too), and explain *why* in
  comments. Many resources here exist because of a specific failure; write it down so
  nobody "simplifies" it away. A new setting or rule deserves a test in
  `tests/offline.tftest.hcl`.
- **Docs**: if you change behaviour or add a setting, update `docs/` in the same PR.
  Every environment variable must be listed in `docs/configuration.md`.
- **No secrets**: no keys, tokens, project IDs, project numbers or real personal data,
  ever, not even in tests. Never create a service account key: everything here works
  without one.

## Common changes, step by step

### Add a model preset

1. Add it to `ml/models/catalog.json`: the Hugging Face id, `gpu_type` (`nvidia-l4`
   or `nvidia-rtx-pro-6000`), `cpu` and `memory` (an L4 needs at least 4 vCPU and
   16 GiB), `max_model_len`, any `vllm_args`, the model card's `temperature` and
   `params`, and whether it is `gated`.
2. Deploy it for real: `make model-deploy PRESET=<your-preset>`, then
   `make model-chat PRESET=<your-preset>`, and chat with it from `make up-cloud`. Try
   an image if it has vision.
3. Note what worked: the GPU, CPU and memory, `max_model_len`, and anything special
   (extra vLLM flags, a gated licence). `make model-delete` when you're done.
4. Add it to the table in `docs/models.md`. Mention the date and the vLLM image
   version you tested with.

### Add a model provider

1. Create `backend/apps/llm/providers/<name>.py` with a class implementing
   `stream(request) -> Iterator[str | Usage]` (see `base.py`). Raise `ProviderError`
   with a meaningful `code`. If the server speaks the OpenAI API, subclass
   `OpenAICompatibleProvider` the way `cloudrun.py` does.
2. Register it in `providers/__init__.py` and add the choice to `LLMModel.Provider`
   (plus a migration: `python manage.py makemigrations llm`).
3. Validate its config in `apps/llm/services.parse_models_config`.
4. Tests with a faked client, and a section in `docs/models.md`.

### Add an API endpoint

1. View + URL in the app it belongs to. Use `ApiError` for failures so the error
   shape stays consistent.
2. Document it in `docs/api.md` (request, response, errors).
3. Tests in `backend/tests/`.
4. Call it from `frontend/src/lib/api.ts` with a typed response. The path must start
   with `/api/`: the web service only forwards `/api/`, `/admin/` and
   `/django-static/` to Django.

## Commit messages

Short imperative subject, e.g. `Add Gemma 3 preset` or `fix(ocr): handle rotated
photos`. Explain the why in the body when it isn't obvious.

## Code of conduct

Be kind; this project exists for learners. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
