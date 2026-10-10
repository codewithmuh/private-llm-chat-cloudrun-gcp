#!/usr/bin/env bash
# OPTIONAL: create a Cloud Storage bucket for the Terraform state.
#
#   ./scripts/bootstrap-state.sh [bucket-name]
#
# You do NOT need this to get started: by default Terraform keeps its state in
# a local file (infra/terraform/terraform.tfstate). You need a state bucket when
#   - GitHub Actions should run `terraform apply` (CI runners are thrown away
#     after each run, so the state must live somewhere shared), or
#   - several people or machines manage the same stack.
#
# Run it once per project. It uses your `make gcp-login` login (through
# scripts/gcloud.sh) and GCP_PROJECT / GCP_REGION from .env.
# Then follow infra/terraform/backend.tf.example.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GCLOUD="$ROOT/scripts/gcloud.sh"

env_value() {
  [ -f "$ROOT/.env" ] || return 0
  sed -n "s/^$1=//p" "$ROOT/.env" | tail -n 1
}
PROJECT="${GCP_PROJECT:-$(env_value GCP_PROJECT)}"
REGION="${GCP_REGION:-$(env_value GCP_REGION)}"
REGION="${REGION:-us-central1}"
[ -n "$PROJECT" ] || {
  echo "Set GCP_PROJECT in .env (your project ID) first." >&2
  exit 1
}
BUCKET="${1:-$PROJECT-tfstate}"

echo "Project : $PROJECT"
echo "Region  : $REGION"
echo "Bucket  : gs://$BUCKET"
read -r -p "Create this state bucket? [y/N] " answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || {
  echo "Aborted."
  exit 1
}

if "$GCLOUD" storage buckets describe "gs://$BUCKET" --project="$PROJECT" >/dev/null 2>&1 </dev/null; then
  echo "The bucket already exists; making sure its settings are right."
else
  # Private, one region, no public access ever: the state holds passwords.
  "$GCLOUD" storage buckets create "gs://$BUCKET" --project="$PROJECT" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention </dev/null
fi

# Versioning: every state write keeps the previous version, so a broken or
# accidentally emptied state can be restored (Cloud Storage console ->
# the bucket -> the object -> Version history).
"$GCLOUD" storage buckets update "gs://$BUCKET" --project="$PROJECT" --versioning </dev/null

cat <<EOF

State bucket ready: gs://$BUCKET

Next (infra/terraform/backend.tf.example):
  cp infra/terraform/backend.tf.example infra/terraform/backend.tf
  ./scripts/terraform.sh init -migrate-state -backend-config="bucket=$BUCKET"

For GitHub Actions, set the repository variable TF_STATE_BUCKET=$BUCKET.
EOF
