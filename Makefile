# Common tasks. Run `make` (or `make help`) to list them.
SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE       := docker compose
COMPOSE_CLOUD := docker compose -f docker-compose.yml -f docker-compose.cloudrun.yml
PY            := backend/.venv/bin/python
# gcloud and Terraform run from their official Docker images: nothing to install.
GCLOUD        := ./scripts/gcloud.sh
TF            := ./scripts/terraform.sh
MODEL_TOOL    := $(GCLOUD) --run python3 ml/cloudrun/deploy.py

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ------------------------------------------------------------- local stack ---

.env:
	cp .env.example .env

.PHONY: up
up: ## Start everything locally; the first time, choose and download an AI model
	@MODEL="$(MODEL)" ./scripts/up.sh

.PHONY: model
model: ## Choose another AI model (MODEL=llama3.2:3b skips the menu, MODEL=mock = no AI)
	@MODEL="$(MODEL)" ./scripts/up.sh --choose

.PHONY: up-cloud
up-cloud: .env ## Local app + your models on Cloud Run GPUs (after make model-deploy)
	@[ -f config/models.cloudrun.json ] || { echo "No config/models.cloudrun.json yet: run make model-deploy PRESET=qwen3-vl-8b first."; exit 1; }
	$(COMPOSE_CLOUD) up -d --build

.PHONY: down
down: ## Stop the local stack (keeps data)
	$(COMPOSE) --profile ollama down

.PHONY: reset
reset: ## Stop and DELETE local data (database, uploads, Ollama models)
	$(COMPOSE) --profile ollama down -v

.PHONY: logs
logs: ## Follow logs of the api and web containers
	$(COMPOSE) logs -f api web

.PHONY: superuser
superuser: ## Create an admin user in the local stack
	$(COMPOSE) exec api python manage.py createsuperuser

# --------------------------------------------------------- backend (local) ---

backend/.venv:
	python3 -m venv backend/.venv
	$(PY) -m pip install -q --upgrade pip
	$(PY) -m pip install -q -r backend/requirements-dev.txt

.PHONY: backend-install
backend-install: backend/.venv ## Create backend/.venv with dev dependencies

.PHONY: backend-dev
backend-dev: backend/.venv ## Run Django on :8000 with SQLite and the in-process mock model (no Docker)
	@# .env (if present) supplies GOOGLE_CLIENT_ID, ADMIN_EMAILS, ...; the
	@# lines after it pin what this no-Docker mode needs.
	set -a; [ -f .env ] && . ./.env; set +a; \
	cd backend && export DATABASE_URL=sqlite:///db.sqlite3 EMAIL_VERIFICATION=none EMAIL_PROVIDER=console \
	  LLM_MODELS_FILE= \
	  LLM_MODELS='[{"id":"mock","name":"Mock (in-process)","provider":"mock","vision":true,"ocr":true,"default":true}]' && \
	  .venv/bin/python manage.py bootstrap && .venv/bin/python manage.py runserver 0.0.0.0:8000

.PHONY: test
test: backend-test frontend-check ## Run all tests and checks

.PHONY: backend-test
backend-test: backend/.venv ## Backend unit tests
	cd backend && .venv/bin/python -m pytest

.PHONY: lint
lint: backend/.venv ## Lint backend (ruff) and frontend (eslint + tsc)
	cd backend && .venv/bin/ruff check . && .venv/bin/ruff format --check .
	cd frontend && npm run lint && npm run typecheck

.PHONY: fmt
fmt: backend/.venv ## Format backend code and Terraform
	cd backend && .venv/bin/ruff format . && .venv/bin/ruff check --fix .
	$(TF) fmt -recursive

# ---------------------------------------------------------------- frontend ---

frontend/node_modules:
	cd frontend && npm ci

.PHONY: frontend-dev
frontend-dev: frontend/node_modules ## Next.js dev server on :3000 (passes /api/ on to the api on :8000)
	cd frontend && API_ORIGIN=http://localhost:8000 npm run dev

.PHONY: frontend-check
frontend-check: frontend/node_modules ## Typecheck, lint and build the frontend
	cd frontend && npm run typecheck && npm run lint && npm run build

# ------------------------------------------------ Google Cloud: log in ---

.PHONY: gcp-login
gcp-login: .env ## Log in to Google Cloud, once (set GCP_PROJECT in .env first)
	$(GCLOUD) login

.PHONY: gcloud
gcloud: ## Any gcloud command, without installing it: make gcloud ARGS="run services list"
	$(GCLOUD) $(ARGS)

# ------------------------------------------------ a model on Cloud Run ---

PRESET ?= qwen3-vl-8b

.PHONY: model-presets
model-presets: ## List the ready-made models for a Cloud Run GPU
	@python3 ml/cloudrun/deploy.py presets 2>/dev/null || $(MODEL_TOOL) presets

.PHONY: model-deploy
model-deploy: ## Deploy one model to a Cloud Run GPU (PRESET=qwen3-vl-8b). Costs money while awake!
	$(MODEL_TOOL) deploy $(PRESET)

.PHONY: model-chat
model-chat: ## Send a test message to the deployed model (PRESET=...; wakes it if asleep)
	$(MODEL_TOOL) chat $(PRESET)

.PHONY: model-status
model-status: ## The model services in your project
	$(MODEL_TOOL) status

.PHONY: model-delete
model-delete: ## Delete the model's service (WEIGHTS=1 also deletes its copy in Cloud Storage)
	$(MODEL_TOOL) delete $(PRESET) $(if $(WEIGHTS),--weights)

# -------------------------------------------- full stack on Google Cloud ---

.PHONY: tf-init
tf-init: ## terraform init (infra/terraform)
	$(TF) init

.PHONY: tf-plan
tf-plan: ## terraform plan
	$(TF) plan

.PHONY: tf-apply
tf-apply: ## terraform apply
	$(TF) apply

.PHONY: deploy
deploy: ## Build the images with Cloud Build, copy the models, roll out with Terraform
	./scripts/deploy.sh

.PHONY: tf-destroy
tf-destroy: ## Tear down the Google Cloud stack (asks first)
	$(TF) destroy
