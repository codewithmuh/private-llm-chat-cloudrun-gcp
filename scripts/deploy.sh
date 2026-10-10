#!/usr/bin/env bash
# Deploy the whole app to Google Cloud: images, model weights, then Terraform.
#
#   ./scripts/deploy.sh                 build, copy the models, terraform apply (asks to confirm)
#   ./scripts/deploy.sh --yes           ... without the confirmation prompt
#   ./scripts/deploy.sh --skip-build    re-apply an existing tag (IMAGE_TAG, or the last deployed one)
#   IMAGE_TAG=v1 ./scripts/deploy.sh    use your own tag instead of the git commit
#
# Needs only Docker: gcloud and Terraform run from their official images
# (scripts/gcloud.sh, scripts/terraform.sh), and your login from
# `make gcp-login`. Settings come from infra/terraform/terraform.tfvars.
#
# The images are built by Cloud Build, IN Google Cloud: only the source code
# (a few MB) is uploaded, never a multi-GB image, and they come out as
# linux/amd64 (what Cloud Run runs) even when you work on an ARM Mac.
#
# On a fresh project the order matters:
#   1. terraform apply -target=terraform_data.foundation
#        the APIs, Artifact Registry, the buckets, the build service account
#   2. Cloud Build: the api, web, search and speech images
#   3. Cloud Build: each model's weights, Hugging Face -> Cloud Storage (once per model)
#   4. terraform apply: database, secrets, and the Cloud Run services, which
#      need the images and the weights to start
#
# Why Terraform does the rollout (instead of `gcloud run deploy`): the
# services (environment, secrets, sizes) are defined in Terraform. If this
# script changed them by itself, the next `terraform apply` would undo it.
# One source of truth: Terraform.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/infra/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
GCLOUD="$ROOT/scripts/gcloud.sh"
TF="$ROOT/scripts/terraform.sh"

AUTO_APPROVE=""
SKIP_BUILD=false
for arg in "$@"; do
  case "$arg" in
    -y | --yes) AUTO_APPROVE="-auto-approve" ;;
    --skip-build) SKIP_BUILD=true ;;
    -h | --help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() {
  printf '\033[31mError:\033[0m %s\n' "$*" >&2
  exit 1
}

# A plain `name = "value"` from terraform.tfvars (empty if it isn't set there).
tfvar() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TFVARS" | tail -n 1; }
turned_off() { grep -qsE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*false" "$TFVARS"; }
tf_output() { "$TF" output -raw "$1" 2>/dev/null || true; }

# ------------------------------------------------------------- preflight ----

docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and try again."
[ -f "$TFVARS" ] || die "No infra/terraform/terraform.tfvars. Create it: cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars, then set project_id."

PROJECT="$(tfvar project_id)"
REGION="$(tfvar region)"
REGION="${REGION:-us-central1}"
[ -n "$PROJECT" ] || die "Set project_id in infra/terraform/terraform.tfvars."
# gcloud.sh takes these over .env, so both tools use the same project.
export GCP_PROJECT="$PROJECT" GCP_REGION="$REGION"

[ -f "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json" ] \
  || die "Not logged in to Google Cloud. Run: make gcp-login"

echo "Project: $PROJECT"
echo "Region:  $REGION"

if [ ! -d "$TF_DIR/.terraform" ]; then
  say "terraform init (downloads the Google provider, once)"
  "$TF" init -input=false
fi

# ------------------------------------------------------------ image tag ----

if [ -n "${IMAGE_TAG:-}" ]; then
  TAG="$IMAGE_TAG"
elif [ "$SKIP_BUILD" = true ] && [ -f "$TF_DIR/image.auto.tfvars" ]; then
  TAG="$(sed -nE 's/^image_tag *= *"([^"]+)".*/\1/p' "$TF_DIR/image.auto.tfvars")"
else
  # The commit: every running container maps to exactly one commit. With
  # uncommitted changes, a time stamp is added, so Cloud Run gets new images.
  TAG="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)"
  if [ -z "$TAG" ]; then
    TAG="build-$(date -u +%Y%m%d-%H%M%S)"
  elif [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    TAG="$TAG-dirty-$(date -u +%H%M%S)"
  fi
fi
[ -n "$TAG" ] || die "No image tag. Set IMAGE_TAG=<tag>."
echo "Images:  $TAG"

# --------------------------------------------------- 1. the foundation ----

say "1/4  Foundation: APIs, Artifact Registry, buckets, build account (terraform apply -target)"
"$TF" apply -input=false -auto-approve -target=terraform_data.foundation -var "image_tag=$TAG"

REGISTRY="$(tf_output registry)"
BUILDER="$(tf_output build_service_account)"
SOURCE_BUCKET="$(tf_output build_source_bucket)"
WEIGHTS_BUCKET="$(tf_output weights_bucket)"
[ -n "$REGISTRY" ] && [ -n "$BUILDER" ] || die "Could not read the Terraform outputs (registry, build_service_account)."

# ------------------------------------------------------- 2. the images ----

if [ "$SKIP_BUILD" = true ]; then
  say "2/4  Images: skipped (--skip-build), using $TAG"
else
  SEARCH=true
  SPEECH=true
  turned_off enable_web_search && SEARCH=false
  turned_off enable_speech_to_text && SPEECH=false
  say "2/4  Images: Cloud Build builds api, web$([ $SEARCH = true ] && echo ", search")$([ $SPEECH = true ] && echo ", speech") (about 10 minutes the first time)"
  "$GCLOUD" builds submit "." \
    --config=infra/cloudbuild/images.yaml \
    --substitutions="_REGISTRY=$REGISTRY,_TAG=$TAG,_SEARCH=$SEARCH,_SPEECH=$SPEECH" \
    --region="$REGION" \
    --service-account="projects/$PROJECT/serviceAccounts/$BUILDER" \
    --gcs-source-staging-dir="gs://$SOURCE_BUCKET/source" \
    --quiet
fi

# Remember the tag, so a plain `terraform apply` later doesn't roll back.
printf '# Written by scripts/deploy.sh: the images that are deployed.\nimage_tag = "%s"\n' "$TAG" >"$TF_DIR/image.auto.tfvars"

# ------------------------------------------------------ 3. the weights ----

say "3/4  Model weights: Hugging Face -> gs://$WEIGHTS_BUCKET (skipped for models already copied)"
while read -r hf_model_id gated; do
  [ -n "$hf_model_id" ] || continue
  gated_flag=""
  [ "$gated" = true ] && gated_flag="--gated"
  # </dev/null: the container must not read the rest of this list from stdin.
  "$GCLOUD" --run python3 ml/cloudrun/deploy.py stage "$hf_model_id" $gated_flag \
    --bucket="$WEIGHTS_BUCKET" --service-account="$BUILDER" </dev/null
done <<EOF
$(tf_output weights_to_stage)
EOF

# ------------------------------------------------------------ 4. apply ----

say "4/4  terraform apply: database, secrets and services (the first time ~15 minutes: Cloud SQL, and each GPU starts once)"
"$TF" apply -input=false $AUTO_APPROVE -var "image_tag=$TAG"

APP_URL="$(tf_output app_url)"
API_SERVICE="$(tfvar app)"
API_SERVICE="${API_SERVICE:-llmchat}-$(tfvar environment | sed 's/^$/dev/')-api"
cat <<EOF

Deployed $TAG.

  The app:  $APP_URL

The models sleep until the first message (then ~1-3 minutes to wake).
Next steps (docs/04-deploy-the-full-stack-on-google-cloud.md):
  - Sign up with an email listed in admin_emails to become an admin.
  - With email_provider = "console", the sign-up code is in the api's logs:
      make gcloud ARGS="logging read 'resource.labels.service_name=$API_SERVICE' --freshness=1h --limit=30"
    or in the console: Cloud Run -> $API_SERVICE -> Logs.
EOF
