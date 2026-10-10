# Model presets for local development

`docker compose` mounts this folder into the api container and loads the file named by
`LLM_MODELS_FILE` (set in `.env`):

| File | Use it when |
|---|---|
| `models.local.json` | Normal local use. **Written by `make up` / `make model`** (`scripts/up.sh`) for the models you downloaded (with Docker Model Runner or Ollama), so it isn't in git |
| `models.mock.json` | You chose "No AI" in the menu (`make model MODEL=mock`): a fake model that streams canned answers, for testing the app itself |
| `models.cloudrun.example.json` | `make model-deploy` writes `models.cloudrun.json` for the models you deployed to Cloud Run; `make up-cloud` loads it (`docker-compose.cloudrun.yml`). The example shows the format |

Each entry is documented in [docs/configuration.md](../docs/configuration.md#llm_models-entries).
After editing a file by hand, reload it: `docker compose exec api python manage.py sync_models`.
`make up` rewrites `models.local.json` every time, so edit the others, or add models in `/admin/`.
