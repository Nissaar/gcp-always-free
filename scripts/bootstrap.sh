#!/usr/bin/env bash
# One-time setup, run from your machine with your own Google account.
#
#   gcloud auth login
#   gcloud auth application-default login
#   ./scripts/bootstrap.sh <project-id> <billing-account-id> [owner/repo]
#
# Settings (environment variables, optional; docs/CONFIGURATION.md lists every variable of this repository):
#   GCP_REGION   us-east1 | us-central1 | us-west1 (the regions with the free e2-micro)   default us-east1
#   GCP_ZONE     a zone inside that region                                                 default <region>-b
#
# Safe to re-run: OpenTofu only changes what differs.
set -euo pipefail

PROJECT_ID=${1:?usage: $0 <project-id> <billing-account-id> [owner/repo]}
BILLING_ACCOUNT_ID=${2:?usage: $0 <project-id> <billing-account-id> [owner/repo]}
REPO=${3:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
REGION=${GCP_REGION:-us-east1}
ZONE=${GCP_ZONE:-${REGION}-b}

[[ $PROJECT_ID =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "<project-id> is the project ID (6-30 lower-case letters, digits, hyphens), got '$PROJECT_ID'" >&2; exit 1; }
[[ $BILLING_ACCOUNT_ID =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ && $BILLING_ACCOUNT_ID != 000000-000000-000000 ]] || { echo "<billing-account-id> looks like 0A1B2C-3D4E5F-6A7B8C (console: Billing -> Account management)" >&2; exit 1; }
[[ $REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]] || { echo "the repository must look like owner/name, got '$REPO'" >&2; exit 1; }
case $REGION in us-east1 | us-central1 | us-west1) ;; *) echo "GCP_REGION must be us-east1, us-central1 or us-west1 (the free e2-micro regions)" >&2; exit 1 ;; esac
[[ $ZONE == "$REGION"-[a-z] ]] || { echo "GCP_ZONE must be a zone of $REGION (for example ${REGION}-b)" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v gcloud >/dev/null || PATH="$HOME/google-cloud-sdk/bin:$PATH"
command -v tofu >/dev/null || { echo "tofu (OpenTofu) is required: docs/WHAT-YOU-DO.md step A1" >&2; exit 1; }

echo "==> Project $PROJECT_ID, billing $BILLING_ACCOUNT_ID, repo $REPO"
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud auth application-default set-quota-project "$PROJECT_ID" >/dev/null

# OpenTofu needs these before it can manage the rest.
gcloud services enable --project "$PROJECT_ID" \
  serviceusage.googleapis.com cloudresourcemanager.googleapis.com \
  cloudbilling.googleapis.com billingbudgets.googleapis.com

REPO_ID=$(gh api "repos/$REPO" --jq .id)

cat > "$ROOT/bootstrap/terraform.tfvars" <<EOF
project_id           = "$PROJECT_ID"
billing_account_id   = "$BILLING_ACCOUNT_ID"
github_repository    = "$REPO"
github_repository_id = "$REPO_ID"
region               = "$REGION"
EOF

cd "$ROOT/bootstrap"
tofu init -input=false
tofu apply -input=false

BUCKET=$(tofu output -raw TF_STATE_BUCKET)

# First run: move the bootstrap state from this laptop into the bucket.
if [ ! -f backend.tf ]; then
  cat > backend.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "$BUCKET"
    prefix = "bootstrap"
  }
}
EOF
  tofu init -input=false -migrate-state -force-copy
  rm -f terraform.tfstate terraform.tfstate.backup
fi

sed -i "s|^\(\s*bucket = \).*|\1\"$BUCKET\"|" "$ROOT/infra/backend.tf"

echo "==> Setting GitHub Actions variables on $REPO"
for name in GCP_PROJECT_ID WIF_PROVIDER PLAN_SA APPLY_SA VM_SA_EMAIL; do
  gh variable set "$name" --repo "$REPO" --body "$(tofu output -raw "$name")"
done
gh variable set GCP_REGION --repo "$REPO" --body "$REGION"
gh variable set GCP_ZONE --repo "$REPO" --body "$ZONE"

echo
echo "Done. Commit bootstrap/backend.tf and infra/backend.tf, then push."
