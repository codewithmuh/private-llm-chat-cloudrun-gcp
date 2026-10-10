#!/usr/bin/env bash
# Runs Google's gcloud CLI from its official Docker image: nothing to install.
#
#   ./scripts/gcloud.sh login                 log in (once): your account + "application default credentials"
#   ./scripts/gcloud.sh run services list     any gcloud command
#   ./scripts/gcloud.sh --run python3 ml/cloudrun/deploy.py presets
#                                             any other command, inside the same image
#
# Your login is kept on your computer in ~/.config/gcloud, the same folder an
# installed gcloud would use (so the two can share it). The repository is
# mounted at /repo, and commands run there.
#
# GCP_PROJECT, GCP_REGION and HF_TOKEN are read from .env (your shell wins).
# GCLOUD_IMAGE picks another image tag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${GCLOUD_IMAGE:-gcr.io/google.com/cloudsdktool/google-cloud-cli:586.0.0-slim}"
CONFIG_DIR="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# One value from .env (KEY=value, optionally quoted), without running the file.
env_value() {
  [ -f "$ROOT/.env" ] || return 0
  sed -n "s/^$1=//p" "$ROOT/.env" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
GCP_PROJECT="${GCP_PROJECT:-$(env_value GCP_PROJECT)}"
GCP_REGION="${GCP_REGION:-$(env_value GCP_REGION)}"
GCP_REGION="${GCP_REGION:-us-central1}"
HF_TOKEN="${HF_TOKEN:-$(env_value HF_TOKEN)}"

docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and try again."
mkdir -p "$CONFIG_DIR"

if [ "${1:-}" = "login" ]; then
  # Two logins in one: gcloud's own, and the "application default credentials"
  # that programs use (Terraform, the local app). A browser link is printed:
  # open it, allow access, and paste the code back here.
  [ -n "$GCP_PROJECT" ] || die "set GCP_PROJECT in .env first (your project ID, e.g. my-llm-chat-123)."
  cmd=(sh -c 'gcloud auth login --update-adc --no-launch-browser --quiet \
    && gcloud config set project "$GCP_PROJECT" --quiet \
    && gcloud auth application-default set-quota-project "$GCP_PROJECT" --quiet \
    && echo && echo "Logged in as $(gcloud config get-value account 2>/dev/null), project $GCP_PROJECT."')
elif [ "${1:-}" = "--run" ]; then
  shift
  cmd=("$@")
else
  cmd=(gcloud "$@")
fi

env_flags=(-e "GCP_REGION=$GCP_REGION" -e "CLOUDSDK_RUN_REGION=$GCP_REGION")
if [ -n "$GCP_PROJECT" ]; then
  env_flags+=(-e "GCP_PROJECT=$GCP_PROJECT" -e "CLOUDSDK_CORE_PROJECT=$GCP_PROJECT")
fi
[ -n "$HF_TOKEN" ] && env_flags+=(-e "HF_TOKEN=$HF_TOKEN")

tty_flags=(-i)
[ -t 0 ] && [ -t 1 ] && tty_flags=(-it)

# Your user id inside the container, so files it writes (the login, and
# config/models.cloudrun.json) belong to you.
exec docker run --rm "${tty_flags[@]}" \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e CLOUDSDK_CONFIG=/gcloud \
  -e PYTHONDONTWRITEBYTECODE=1 \
  "${env_flags[@]}" \
  -v "$CONFIG_DIR:/gcloud" \
  -v "$ROOT:/repo" \
  -w /repo \
  "$IMAGE" "${cmd[@]}"
