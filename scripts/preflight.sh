#!/usr/bin/env bash
# preflight.sh: READ-ONLY check of everything you need before ./scripts/bootstrap.sh and the first plan.
# It changes nothing: no file is written, no cloud call that creates or changes anything, no GitHub setting is touched.
#
#   ./scripts/preflight.sh                                         tools, logins, repository state; reads bootstrap/terraform.tfvars if it exists
#   ./scripts/preflight.sh <project-id> <billing-account-id> [owner/repo]    also checks the arguments you will give bootstrap.sh
#   ./scripts/preflight.sh --offline                               skip every check that needs the network (Google, GitHub)
#
# Settings it understands (same names as bootstrap.sh): GCP_REGION (default us-east1), GCP_ZONE (default <region>-b).
# Exit code 0 = nothing to fix (warnings are advice), 1 = at least one FAIL, with what to do about it.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OFFLINE=false
ARGS=()
for a in "$@"; do
  case $a in
    --offline) OFFLINE=true ;;
    -h | --help) sed -n 2,10p "$0"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
PROJECT=${ARGS[0]:-}
BILLING=${ARGS[1]:-}
REPO=${ARGS[2]:-}
REGION=${GCP_REGION:-us-east1}
ZONE=${GCP_ZONE:-${REGION}-b}
command -v gcloud > /dev/null 2>&1 || PATH="$HOME/google-cloud-sdk/bin:$PATH"

fails=0
warns=0
ok() { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n%s\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

section "1. Tools on this machine"
for t in git jq curl python3; do
  if have "$t"; then ok "$t"; else fail "$t is not installed (sudo apt install $t)"; fi
done
if have tofu; then
  v=$(tofu version 2> /dev/null | sed -n '1s/[^0-9.]*\([0-9][0-9.]*\).*/\1/p')
  if [ -n "$v" ] && version_ge "$v" 1.12.0; then ok "tofu (OpenTofu) $v"; else fail "OpenTofu 1.12.0 or newer is required, found '${v:-none}' (docs/WHAT-YOU-DO.md step A1). Terraform is not supported: use tofu"; fi
else
  fail "tofu (OpenTofu) is not installed (docs/WHAT-YOU-DO.md step A1)"
fi
if have gcloud; then ok "gcloud $(gcloud version 2> /dev/null | head -n1 | sed 's/Google Cloud SDK //')"; else fail "the Google Cloud CLI (gcloud) is not installed: https://cloud.google.com/sdk/docs/install"; fi
if have gh; then ok "gh $(gh --version 2> /dev/null | head -n1 | cut -d' ' -f3)"; else fail "the GitHub CLI (gh) is not installed: https://cli.github.com/"; fi
if have shellcheck; then ok "shellcheck (optional)"; else warn "shellcheck not installed: only needed for the checks in the README"; fi

section "2. Variables you must set"
if [ -n "$PROJECT" ]; then
  if [[ $PROJECT =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then ok "project id has the right shape"; else fail "project id '$PROJECT' is not a project ID (6-30 lower-case letters, digits, hyphens; not the name or the number)"; fi
fi
if [ -n "$BILLING" ]; then
  if [[ $BILLING =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ && $BILLING != 000000-000000-000000 ]]; then ok "billing account id has the right shape"; else fail "billing account id '$BILLING' must look like 0A1B2C-3D4E5F-6A7B8C (console: Billing -> Account management)"; fi
fi
if [ -n "$REPO" ]; then
  if [[ $REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]]; then ok "repository $REPO"; else fail "repository '$REPO' must look like owner/name"; fi
fi
case $REGION in
  us-east1 | us-central1 | us-west1) ok "region $REGION (a free e2-micro region)" ;;
  *) fail "GCP_REGION '$REGION' has no free e2-micro: use us-east1, us-central1 or us-west1" ;;
esac
if [[ $ZONE == "$REGION"-[a-z] ]]; then ok "zone $ZONE"; else fail "GCP_ZONE '$ZONE' is not a zone of $REGION"; fi
TFV=$ROOT/bootstrap/terraform.tfvars
if [ -f "$TFV" ]; then
  ok "bootstrap/terraform.tfvars exists (git-ignored)"
  for k in project_id billing_account_id github_repository github_repository_id; do
    val=$(sed -n -E "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TFV" | head -n1)
    if [ -z "$val" ]; then fail "bootstrap/terraform.tfvars: $k is not set"
    elif [[ $val == *"<"*">"* || $val == "000000-000000-000000" || $val == "123456789" || $val == "my-project-123456" ]]; then fail "bootstrap/terraform.tfvars: $k still holds a placeholder"
    else ok "bootstrap/terraform.tfvars: $k is set"; fi
  done
elif [ -z "$PROJECT$BILLING" ]; then
  fail "nothing to check yet: there is no bootstrap/terraform.tfvars and you gave no arguments. Run  ./scripts/preflight.sh <project-id> <billing-account-id> <owner/repo>  (the same arguments you will give bootstrap.sh)"
fi

section "3. Files of this repository"
left=$(cd "$ROOT" && grep -rIn -E '<your-[a-z-]+>' --include='*.tf' --include='*.tfvars' --include='*.yml' --include='*.yaml' --include='*.tftpl' . 2> /dev/null | grep -v -E '^\./(docs|\.git)/|^\./infra/backend\.tf|\.example|\.env|^[^:]+:[0-9]+:[[:space:]]*(#|//)' | head -n 5)
if [ -z "$left" ]; then ok "no <your-...> placeholder in the code files"; else fail "placeholders left in files you would commit:"; printf '%s\n' "$left" | sed 's/^/           /'; fi
if grep -q '<your-project-id>' "$ROOT/infra/backend.tf" 2> /dev/null; then
  warn "infra/backend.tf still has the placeholder bucket name: scripts/bootstrap.sh writes it; commit the file afterwards"
else
  ok "infra/backend.tf has been written for your project"
fi
if [ -f "$ROOT/bootstrap/backend.tf" ]; then ok "bootstrap/backend.tf exists (bootstrap already ran once)"; else ok "no bootstrap/backend.tf yet (the first bootstrap writes it)"; fi
if [ -n "$(cd "$ROOT" && git ls-files '*.tfvars' '*.tfstate' '*.pem' '*.key' '.env' 2> /dev/null | grep -v -E '\.example$')" ]; then fail "a tfvars, state, key or .env file is tracked by git: git rm --cached it (it may hold secrets)"; else ok "no tfvars, state, key or .env file is tracked by git"; fi
if (cd "$ROOT" && tofu fmt -check -recursive > /dev/null 2>&1); then ok "tofu fmt -check"; else warn "tofu fmt -check reports unformatted files: tofu fmt -recursive"; fi

section "4. Logins and repository settings (network)"
if [ "$OFFLINE" = true ]; then
  warn "--offline: Google and GitHub were not asked"
else
  if have gh; then
    if gh auth status > /dev/null 2>&1; then ok "gh is logged in"; else fail "gh is not logged in: gh auth login"; fi
  fi
  if have gcloud; then
    acct=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2> /dev/null | head -n1)
    if [ -n "$acct" ]; then ok "gcloud is logged in (an account is active)"; else fail "gcloud is not logged in: gcloud auth login"; fi
    # the token itself is never printed
    if gcloud auth application-default print-access-token > /dev/null 2>&1; then ok "application-default credentials exist (OpenTofu uses them)"; else fail "no application-default credentials: gcloud auth application-default login"; fi
    proj=${PROJECT:-$(sed -n -E 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$TFV" 2> /dev/null | head -n1)}
    if [ -n "$proj" ] && [[ $proj != *"<"* ]]; then
      if gcloud projects describe "$proj" --format='value(projectId)' > /dev/null 2>&1; then ok "project $proj exists and you can read it"; else fail "cannot read project $proj: wrong id, or your account has no access (create the project first, README step 1)"; fi
      be=$(gcloud billing projects describe "$proj" --format='value(billingEnabled)' 2> /dev/null || true)
      case $be in
        True) ok "billing is linked to project $proj" ;;
        False) fail "billing is NOT linked to project $proj (console: Billing -> Account management -> link the project): the bootstrap needs it" ;;
        *) warn "could not read the billing state of $proj (verify in the console)" ;;
      esac
    fi
  fi
  if have gh && gh auth status > /dev/null 2>&1; then
    slug=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null || true)}
    if [ -z "$slug" ]; then
      warn "no GitHub repository found for this folder yet: create YOUR private copy first (README, step 1)"
    else
      priv=$(gh repo view "$slug" --json isPrivate,isFork --jq '"\(.isPrivate) \(.isFork)"' 2> /dev/null || true)
      case $priv in
        "true false") ok "$slug is private and is not a fork" ;;
        "true true") warn "$slug is a private fork: prefer a clone pushed to a new private repository (a fork of a public repository cannot be made independent of it)" ;;
        "false"*) fail "$slug is PUBLIC: the plan output and the CI trust belong in a PRIVATE repository (gh repo edit $slug --visibility private --accept-visibility-change-consequences)" ;;
        *) warn "could not read the visibility of $slug (no access? wrong name?)" ;;
      esac
      # verify: a 404 or 403 only means we could not read the setting
      pol=$(gh api "repos/$slug/actions/permissions/workflow" --jq .default_workflow_permissions 2> /dev/null || true)
      case $pol in
        read) ok "Actions default token permission is read" ;;
        write) fail "Actions default token permission is write: Settings -> Actions -> General -> Workflow permissions -> Read repository contents" ;;
        *) warn "could not read the Actions workflow permissions (verify in Settings -> Actions -> General)" ;;
      esac
      fpr=$(gh api "repos/$slug/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2> /dev/null || true)
      if [ -n "$fpr" ]; then
        if [ "$fpr" = all_external_contributors ]; then ok "fork pull requests need approval from you"; else warn "fork pull request approval is '$fpr': set Settings -> Actions -> General -> Fork pull request workflows -> Require approval for all external contributors"; fi
      else
        warn "could not read the fork pull request approval setting (verify in Settings -> Actions -> General)"
      fi
      ss=$(gh api "repos/$slug" --jq '.security_and_analysis.secret_scanning.status // empty' 2> /dev/null || true)
      if [ "$ss" = enabled ]; then ok "secret scanning is enabled"; else warn "secret scanning is not enabled or not readable: Settings -> Code security (verify; it can need GitHub's paid plan on a private repository)"; fi
      br=$(gh api "repos/$slug/branches/main/protection" --jq .url 2> /dev/null || true)
      if [ -n "$br" ]; then ok "branch main is protected"; else warn "branch main has no protection (or the plan does not offer it on private repositories): do not give write access to anybody you do not trust; the apply identity trusts the main branch (README, security notes)"; fi
    fi
  fi
fi

section "Result"
if [ "$fails" -eq 0 ]; then
  printf '  Nothing to fix (%d warning(s)). Next: ./scripts/bootstrap.sh <project-id> <billing-account-id>  (README, step 4)\n' "$warns"
  exit 0
fi
printf '  %d thing(s) to fix (the [FAIL] lines above), %d warning(s). Nothing was changed by this script.\n' "$fails" "$warns"
exit 1
