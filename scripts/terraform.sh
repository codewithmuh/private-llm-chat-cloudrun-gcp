#!/usr/bin/env bash
# Runs Terraform from its official Docker image: nothing to install.
#
#   ./scripts/terraform.sh init
#   ./scripts/terraform.sh plan
#   ./scripts/terraform.sh apply
#
# It runs in infra/terraform and signs in to Google with the "application
# default credentials" that `make gcp-login` saved in ~/.config/gcloud.
# Providers are downloaded once into infra/terraform/.terraform.
# TERRAFORM_IMAGE picks another version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TERRAFORM_IMAGE:-hashicorp/terraform:1.16.4}"
CONFIG_DIR="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
ADC="$CONFIG_DIR/application_default_credentials.json"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and try again."

auth_flags=()
if [ -f "$ADC" ]; then
  auth_flags=(-v "$CONFIG_DIR:/gcloud:ro" -e GOOGLE_APPLICATION_CREDENTIALS=/gcloud/application_default_credentials.json)
elif [ "${1:-}" != "fmt" ] && [ "${1:-}" != "validate" ] && [ "${1:-}" != "test" ]; then
  echo "Note: no Google login found in $CONFIG_DIR. Log in first: make gcp-login" >&2
fi

tty_flags=(-i)
[ -t 0 ] && [ -t 1 ] && tty_flags=(-it)

exec docker run --rm "${tty_flags[@]}" \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e TF_IN_AUTOMATION \
  -e TF_INPUT \
  ${auth_flags[@]+"${auth_flags[@]}"} \
  -v "$ROOT:/repo" \
  -w /repo/infra/terraform \
  "$IMAGE" "$@"
