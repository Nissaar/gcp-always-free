# Configuration: every variable of this repository

Everything that is yours (project, billing account, GitHub names, region) or a matter of taste (sizes, switches) is a variable.
Nothing of the original author is left in the defaults: **required** variables have no default and fail with a message that says
what is wrong. `./scripts/preflight.sh` checks them (read-only) before you start. Examples use placeholders only: `<your-...>`.

Where a value is set:

| Where | How |
|---|---|
| **tfvars** | `bootstrap/terraform.tfvars` or `infra/terraform.tfvars` (git-ignored; `scripts/bootstrap.sh` writes the first one; `*.tfvars.example` shows the format) |
| **Actions variable** | GitHub: repository **Settings -> Secrets and variables -> Actions -> Variables**. `scripts/bootstrap.sh` sets them; CI passes them to OpenTofu as `TF_VAR_*`. There are **no Actions secrets**: the login is keyless |
| **env** | exported in your shell for a script (`GCP_REGION=us-central1 ./scripts/bootstrap.sh ...`) |
| **code default** | the `default` in a `.tf` file; change it in a pull request, read the plan, merge, apply |

## 1. What you MUST set (nothing else is needed for a first plan)

| Name | Meaning | Set in | Example |
|---|---|---|---|
| project id | the Google Cloud project ID (not the name or the number); the project must exist and have billing linked | 1st argument of `scripts/bootstrap.sh`, then `project_id` and the Actions variable `GCP_PROJECT_ID` | `<your-project-id>` |
| billing account id | billing account for budgets (console: Billing -> Account management) | 2nd argument of `bootstrap.sh`, `billing_account_id` | `0A1B2C-3D4E5F-6A7B8C` |
| GitHub repository | YOUR private copy; the only repository the keyless login trusts | 3rd argument of `bootstrap.sh` (default: the repository of the current folder), `github_repository` | `<your-github-user>/<your-private-repo>` |

The numeric repository id (`github_repository_id`) is read by `bootstrap.sh` from GitHub; the trust is bound to it, so a deleted and
re-created repository of the same name cannot inherit access.

## 2. OpenTofu variables, `bootstrap/` (applied from your laptop, never by CI)

| Variable | Meaning | Default | Required | Validation |
|---|---|---|---|---|
| `project_id` | project that holds the VM and the state | none | yes | project ID shape |
| `region` | region of the state bucket; must be a free-tier region | `us-east1` | no | `us-east1`, `us-central1`, `us-west1` |
| `billing_account_id` | billing account for the budgets | none | yes | `XXXXXX-XXXXXX-XXXXXX`, not the zeros placeholder |
| `github_repository` | `owner/name` of your private copy | none | yes | `owner/name` |
| `github_repository_id` | numeric repository id (set by `bootstrap.sh`) | none | yes | digits, not the example |
| `guard_budget_amount` | monthly threshold for spend beyond the free tier; **the kill switch trips when it is passed** | `1` | no | whole number 1 to 100 |
| `trial_budget_amount` | trial credit, for the burn-rate alerts | `300` | no | whole number >= 1 |
| `enable_billing_kill_switch` | detach billing from the project when the guard budget is passed | `true` | no | keep `true` |
| `kill_switch_dry_run` | only log what the kill switch would do | `false` (live) | no | |
| `build_region` (`bootstrap/cloudbuild.tf`) | region of the Artifact Registry repository for the build farm | `us-central1` | no | |
| `images_keep_count` (`bootstrap/cloudbuild.tf`) | versions kept per image (stays under the free 0.5 GB) | `3` | no | 1 to 10 |

`scripts/bootstrap.sh` rewrites `bootstrap/terraform.tfvars` on every run: change the optional settings in the `.tf` files, not only in that file.

## 3. OpenTofu variables, `infra/` (applied by CI)

| Variable | Meaning | Default | Required | Validation / note |
|---|---|---|---|---|
| `project_id` | project ID; Actions variable `GCP_PROJECT_ID` | none | yes | project ID shape |
| `region` | Actions variable `GCP_REGION` (optional) | `us-east1` | no | free-tier regions only |
| `zone` | Actions variable `GCP_ZONE` (optional) | `us-east1-b` | no | must be inside `region` |
| `vm_name` | instance name | `free-vm` | no | valid instance name |
| `vm_service_account_email` | runtime service account made by `bootstrap/`; Actions variable `VM_SA_EMAIL` | none | yes | `...@<project>.iam.gserviceaccount.com` |
| `image` | boot image (read at creation only) | `debian-cloud/debian-13` | no | |
| `disk_size_gb` | boot disk; the free tier covers 30 GB of standard disk | `30` | no | 10 to 30 |
| `deletion_protection` | block deletion of the VM; set `false` before a planned destroy | `true` | no | |
| `enable_tailscale_direct_ipv6` | open inbound UDP 41641 over IPv6 (Tailscale direct connections); `false` if you do not use Tailscale | `true` | no | |
| `patch_installer` | `osconfig` (Google VM Manager, weekly) or `unattended` (apt on the VM) | `osconfig` | no | one of the two |
| `patch_reboot_mode` | `alert`, `staggered` or `none` (what happens when an update needs a reboot) | `alert` | no | one of the three |
| `build_region`, `github_owner`, `github_app_installation_id`, `github_token_secret_version`, `build_repos` | the optional Cloud Build farm (docs/BUILD-FARM.md); off while `github_app_installation_id = 0` | off | no | `github_owner` is required once the farm is on |

Fixed on purpose (not variables, so a typo cannot start billing): machine type `e2-micro`, disk type `pd-standard`, network tier, IPv6 only.

## 4. GitHub Actions variables (all set by `scripts/bootstrap.sh`)

| Name | Meaning | Required |
|---|---|---|
| `GCP_PROJECT_ID` | project ID; **while it is empty every credential job is skipped** (unconfigured template) | yes |
| `WIF_PROVIDER` | Workload Identity provider (the keyless trust, bound to your repository id) | yes |
| `PLAN_SA`, `APPLY_SA` | the service accounts of the plan identity (any branch or pull request of your repository) and the apply identity (manual run on `main` only) | yes |
| `VM_SA_EMAIL` | runtime service account of the VM | yes |
| `GCP_REGION`, `GCP_ZONE` | region and zone (default `us-east1`, `us-east1-b`) | no |

All of these are identifiers, not secrets. There are no Actions secrets in this repository.

## 5. Environment variables of the scripts

| Variable | Used by | Meaning | Default |
|---|---|---|---|
| `GCP_REGION` | `bootstrap.sh`, `preflight.sh` | region of the VM and the state bucket | `us-east1` |
| `GCP_ZONE` | `bootstrap.sh`, `preflight.sh` | zone | `<region>-b` |

Internal hooks, not settings: `PATCH_ROOT`, `PATCH_NO_SYSTEMD`, `KUMA_LOCAL_URL`, `SYNC_REPO_DIR`, `SYNC_OUT_DIR` (the offline tests).

## 6. Pinned versions in the workflows

`TOFU_VERSION`, `TRIVY_VERSION`, `TFLINT_VERSION` (`tofu.yml`), `GITLEAKS_VERSION` + `GITLEAKS_SHA256` (`gitleaks.yml`: change both
together, the checksum comes from the release's checksums file). Actions are pinned to commit SHAs; Renovate proposes bumps.

## 7. Settings of the stacks on the VM (`.env` on the VM, never in git)

| Stack | Variable | Meaning | Default |
|---|---|---|---|
| kuma | `TS_HOSTNAME`, `TS_AUTHKEY` | tailnet device name; optional auth key (empty: log in with the link in the logs) | `kuma-gcp`, empty |
| kuma | `KUMA_LOCATION`, `MONITOR_DIR` | location label and folder of the monitors in the git repository | `gcp`, `uptime-kuma/remote-monitors/gcp` |
| kuma | `KUMA_ADMIN_USER`, `KUMA_ADMIN_PASSWORD` | the Kuma admin you create on the first visit | none: you choose |
| kuma | `GIT_URL`, `GIT_BRANCH`, `GIT_USERNAME`, `GIT_TOKEN`, `SYNC_PERIOD` | git source of the monitors (read-only token; the VM has no IPv4) | none, `main`, empty, empty, `600` |
| kuma | `KUMA_WORKER_URL`, `KUMA_TOKEN`, `KUMA_NOTIFICATION_NAME`, `KUMA_PUSH_URL`, `PUSH_PERIOD` | optional alert webhook and heartbeat | empty |
| kuma | `AUTOKUMA_IMAGE`, `COMPOSE_PROFILES`, `GHCR_MIRROR` | AutoKuma comes through a ghcr.io pull-through cache reachable over the tailnet (the VM has no IPv4) | see `.env.example` |
| kuma | `TAILSCALE_IMAGE`, `KUMA_IMAGE`, `GIT_IMAGE`, `CURL_IMAGE`, `SOCAT_IMAGE` | container images; put a version tag to pin | newest |
| patching | `PATCH_NTFY_URL`, `PATCH_ALERT_URL`, `PATCH_HEARTBEAT_URL` in `/etc/patch-agent.env` | where patch status goes (empty = nowhere); see `patch/README.md` | empty |

The Kuma stack does not start until you create its `.env` on the VM: a VM without them is a plain Debian machine with Docker.

## 8. Fixed on purpose (not variables)

VPC `free-tier-vpc` and subnet `10.10.0.0/24`, service accounts `tf-plan`, `tf-apply`, `vm-free-tier`, `billing-kill-switch`,
`kill-switch-build`, `cloud-build-amd64`, `ar-pull-cluster`, the Workload Identity pool `github`, the Artifact Registry repository `images`,
the secret `cloudbuild-github-token`. The sibling repositories refer to some of them by name.
