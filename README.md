# gcp-always-free

One **always-free Google Cloud VM** (e2-micro, IPv6 only), a Cloud Build "amd64 build farm" (optional), budget alerts and a **hard
billing kill switch**, managed with [OpenTofu](https://opentofu.org) (`tofu`, not Terraform) and deployed by GitHub Actions with
a keyless login (Workload Identity Federation: no JSON key anywhere).

> **Use it from a PRIVATE repository of your own, not from a fork** (reasons in [Use it](#use-it), step 1).
> Community code, not affiliated with Google. Free-tier limits and prices change: check Google's current pages.
> `Nissaar` below is the GitHub account that publishes this repository; `<your-...>` is always a value of yours.
> Every variable is listed in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## What you get for free

| Piece | Defined in | Free? |
|---|---|---|
| e2-micro VM, Debian 13, 30 GB `pd-standard` disk, `us-east1-b` | `infra/vm.tf` | Yes (1 e2-micro and 30 GB standard disk per billing account, in `us-east1`, `us-central1` or `us-west1`) |
| External **IPv6 only**, no external IPv4 | `infra/vm.tf`, `infra/network.tf` | Yes (an external IPv4 would be about USD 3.65 a month) |
| Custom VPC: SSH only through IAP, inbound UDP 41641 over IPv6 for Tailscale (switchable), everything else blocked | `infra/network.tf` | Yes |
| Docker, an optional Uptime Kuma stack that starts only when you create its `.env`, automatic security updates, no swap | `infra/startup.sh.tftpl`, `stacks/` | Yes |
| OS patching with Google VM Manager (no automatic reboot), patch agent, reboot reminders | `infra/patch-deployment.tf`, `patch/` | Yes |
| State bucket (versioned, private) | `bootstrap/` | Yes (5 GB) |
| Keyless GitHub to GCP login (Workload Identity) with two identities: `tf-plan` (reads compute) and `tf-apply` | `bootstrap/main.tf` | Yes |
| Budget alerts: spend beyond the free tier, and use of the USD 300 trial credit | `bootstrap/main.tf` | Yes |
| **Billing kill switch**: detaches billing when spend beyond the free tier passes USD 1 | `bootstrap/killswitch.tf` | Yes (Pub/Sub, Cloud Run functions, Cloud Build free tiers) |
| Cloud Build amd64 build farm into Artifact Registry (off until you enable it) | `bootstrap/cloudbuild.tf`, `infra/cloudbuild*.tf`, `cloudbuild/amd64.yaml` | Within 2,500 build-minutes and 0.5 GiB a month |

Settings that keep the VM free (machine type, disk type, network tier, region) are fixed in code or validated, so a typo cannot quietly
start billing. The design, the IPv6-only constraints and the egress arithmetic: [docs/DESIGN.md](docs/DESIGN.md); the build farm:
[docs/BUILD-FARM.md](docs/BUILD-FARM.md).

## Who it is for

You want one small always-on Linux VM on Google Cloud for free (a monitor, a tailnet node, a build box), managed from git, and you
accept that it has **no IPv4 address**: it cannot reach github.com or ghcr.io directly (neither answers on IPv6), only hosts that do
(Docker Hub, Debian mirrors, Tailscale peers). It is **not** a managed service: you read the plans, and Google's free tier can change.

## Accounts, tools and the one thing that can still cost money

- A **Google account** and a **Google Cloud project with billing enabled** (a free trial gives USD 300 for 90 days; a billing account needs a
  payment method). Create the project and link the billing account in the console first: the bootstrap does not create the project, it only
  runs `gcloud config set project` on it. You need the **project id** and the **billing account id** (console: Billing -> Account management).
- A **GitHub account** and `gh`, logged in (`gh auth login`).
- On your laptop: `git`, `gh`, `jq`, `python3`, [OpenTofu](https://opentofu.org/docs/intro/install/) 1.12 or newer (CI pins 1.13.9) and the
  [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`). Install steps the authors used: [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) step A1.

**The one thing that can still cost money:** network **egress above 1 GB a month** from the VM (Premium tier; the Kuma stack uses about 0.7 GB,
so do not lower monitor intervals below 600 s). Everything else that costs is refused by design (IPv4, other machine types, bigger disks are validated
against) or capped by the **kill switch**, which detaches billing once spend beyond the free tier passes USD 1 (everything paid then stops until you re-link billing).
Billing data lags by hours, so a few dollars can accrue before it trips: look at **Billing -> Reports** after the first week. When the trial ends (90 days or
USD 300), Google stops resources and deletes them 30 days later unless the billing account is upgraded.

## Use it

Every command runs on your laptop in the folder of your private copy. Steps marked **verify** were not run by anyone yet.

**1. Make your own PRIVATE copy** (clone, then push to a new private repository):

```bash
git clone https://github.com/Nissaar/gcp-always-free.git my-gcp-free && cd my-gcp-free
git remote rename origin upstream
gh repo create <your-github-user>/<your-private-repo> --private --source . --remote origin --push
git remote -v          # origin = your private copy, upstream = this repository
```

Why private and not a fork: the saved plan files (workflow artifacts) can contain values that are secret, pull-request comments show your
plan, and CI can act on your project; a public repository lets strangers read all of it, and a fork of a public repository is always public.
Why clone and not "Use this template": the shared history lets you merge updates later ([Keep it up to date](#keep-it-up-to-date)).

**2. Harden the repository settings now** (web: **Settings**; the commands are **verify**):

```bash
SLUG=<your-github-user>/<your-private-repo>
# Actions: read-only default token; fork pull requests need your approval; Actions may not approve pull requests
gh api -X PUT "repos/$SLUG/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/$SLUG/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
```

Also in **Settings -> Code security**: enable secret scanning and push protection (a private repository may need GitHub's paid secret-protection
plan; the gitleaks workflow scans every push and pull request either way). **Protect `main`** (pull request and one review, enforced for admins):
branch protection on a private repository needs GitHub Pro, Team or Enterprise; on the Free plan keep the repository single-owner.
`tf-apply` trusts manual runs on `main` only, so whoever can push to `main` and click "Run workflow" can apply.

**3. Sign in to Google** (two browser windows open; pick your account in both):

```bash
gcloud auth login
gcloud auth application-default login
```

**4. Check everything before touching anything** (read-only):

```bash
./scripts/preflight.sh <your-project-id> <your-billing-account-id> <your-github-user>/<your-private-repo>
```

It lists tools, variables, files, logins, the project and its billing link, and your repository settings as `[ ok ]`, `[warn]` or `[FAIL]`,
and ends with `Nothing to fix (...)` or with what to fix. Fix every `[FAIL]` and run it again. The warning about `infra/backend.tf` is expected.
Region and zone default to `us-east1` / `us-east1-b`; to change them export `GCP_REGION` (and `GCP_ZONE`) first, for this step and the next.

**5. Bootstrap** (one command: enables the APIs, applies `bootstrap/`, moves its state into the bucket, writes the bucket name into `infra/backend.tf`, sets the GitHub variables):

```bash
./scripts/bootstrap.sh <your-project-id> <your-billing-account-id>
```

It validates its arguments, runs `gcloud config set project`, writes `bootstrap/terraform.tfvars` (git-ignored) and runs `tofu apply`: **OpenTofu prints
the full plan and waits for you to type `yes`: that is your first plan.** Expected: `==> Project <id>, billing <id>, repo <owner/name>`,
the plan, `==> Setting GitHub Actions variables on <owner/name>` and `Done. Commit bootstrap/backend.tf and infra/backend.tf, then push.`
The variables it sets: `GCP_PROJECT_ID`, `WIF_PROVIDER`, `PLAN_SA`, `APPLY_SA`, `VM_SA_EMAIL`, `GCP_REGION`, `GCP_ZONE`. It is safe to re-run.

**6. Commit the two backend files (by name) and push; CI now plans `infra/`:**

```bash
git status --short                                   # bootstrap/backend.tf (new), infra/backend.tf (modified)
git add bootstrap/backend.tf infra/backend.tf && git commit -m "chore: set state bucket" && git push
```

**7. Read the plan.** GitHub: **Actions -> tofu**: the run of your push (jobs `validate`, `trivy`, `patch-tests`, then `plan`). When it is green, read the
plan in the run summary (`Plan: N to add, 0 to change, 0 to destroy.`). If the `plan` job is *skipped*, the variable `GCP_PROJECT_ID` is empty: step 5 did not finish.

**8. Apply it yourself:** **Actions -> tofu -> Run workflow -> branch `main` -> type `apply`**. It applies exactly the plan of the latest `main` commit.

**9. Reach the VM:** `gcloud compute ssh free-vm --zone <your-zone> --tunnel-through-iap` (OS Login: access follows your IAM roles, no SSH keys). The optional
Kuma stack needs its own settings on the VM: [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) section C.

Only want to read a plan on your laptop, without CI? (**verify**)
```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars   # fill in your values; git-ignored
tofu -chdir=infra init && tofu -chdir=infra plan           # needs gcloud auth application-default login
```

## How the pieces fit with the other three repositories

`gcp-always-free` is independent: use it alone, or as a second small machine next to `oracle-always-free`. If you run both, the Oracle `micro-edge`
VM can host a ghcr.io pull-through cache that this IPv6-only VM reaches over Tailscale (docs/WHAT-YOU-DO.md section C), and the build farm
(`docs/BUILD-FARM.md`) can build amd64 images that the cluster of `k8s-free-gitops` pulls. Recipes: [docs/RECIPES.md](docs/RECIPES.md).

## Keep it up to date

```bash
git fetch upstream
git log --oneline HEAD..upstream/main          # what is new; read docs/CHANGELOG.md
git switch -c update-from-upstream
git merge upstream/main                        # keep YOUR version of infra/backend.tf and anything you edited
git push -u origin update-from-upstream        # open a pull request: read the plan comment, merge, then apply
```

Never merge a plan you have not read. `docs/CHANGELOG.md` says when a change needs a manual step.

## Spending caps

- **Kill switch** (`bootstrap/killswitch.tf`, live by default, `enable_billing_kill_switch`): the "beyond the free tier" budget publishes to Pub/Sub and a small
  function (`bootstrap/killswitch/main.py`, unit-tested) **unlinks the billing account from the project** once spend passes `guard_budget_amount` (default 1). Everything paid then stops,
  the VM and the build farm included, until you re-link billing (console, Billing, Account management). `kill_switch_dry_run = true` only logs. Change the defaults in
  `bootstrap/variables.tf`, not in `terraform.tfvars` (the script rewrites that file).
- **Budget alerts** mail you at 10 %, 50 % and 100 % of the guard budget, and as the trial credit is used. Budgets lag by hours: they are a safety net, not a meter.
- Other ways to pay: a public IPv4 address (the VM is IPv6 only on purpose; it would trip the kill switch within a week); Cloud Build beyond 2,500 minutes; Artifact Registry beyond 0.5 GiB;
  a bigger disk, another machine type or region (validated against, but your own edits are yours); a second e2-micro in another project of the same billing account.

## Tear it down

1. `deletion_protection = false` (default in `infra/variables.tf`), commit, push, run the apply: the VM may now be deleted.
2. Remove the resources from `infra/` (or `tofu -chdir=infra destroy` from your laptop with your own login), apply.
3. `bootstrap/`: the quickest complete teardown is to delete the project: `gcloud projects delete <your-project-id>` (it is recoverable for about 30 days). Doing it by `tofu destroy` of
   `bootstrap/` is **verify** (never run: the state bucket holds its own state).
4. Remove the GitHub variables, then re-link or close the billing account if you want no billing relationship at all.

## Troubleshooting (real problems from building this)

| What you see | Cause and fix |
|---|---|
| `Invalid value for variable` mentioning `project_id`, `billing_account_id`, `github_repository` or `github_repository_id` | A required value is missing or still a placeholder. Run `./scripts/preflight.sh <project-id> <billing-account-id> <owner/repo>`; every variable and its format is in docs/CONFIGURATION.md. |
| The `plan` job is skipped | The Actions variable `GCP_PROJECT_ID` is empty (bootstrap not finished), or the pull request comes from a fork (fork pull requests never get a plan on purpose). |
| `No successful plan for <sha>` when you apply | Apply uses the plan saved by the `push` run of the same `main` commit: push to `main` (or re-run its workflow), wait for it to pass, then apply. Artifacts expire after 7 days. |
| The kill-switch function fails to build ("cannot fetch source" in a new project) | In new projects the default compute service account cannot fetch the function source. The code builds it as its own service account (`google_service_account.kill_switch_build`); keep that if you edit `bootstrap/killswitch.tf`. |
| The VM lost its network access to ghcr.io or github.com | Those hosts have no IPv6 and the VM is IPv6 only. Pull from a mirror reachable over IPv6 (the stack uses a pull-through cache on another host over Tailscale) and use a git mirror instead of github.com. Docker Hub and Debian mirrors work over IPv6. |
| Docker IPv6 networking does not work on Debian 13 | Docker 26 needs `"experimental": true, "ip6tables": true` in `/etc/docker/daemon.json` for IPv6 NAT on a dual-stack network; `infra/startup.sh.tftpl` writes it. |
| Billing was detached and everything stopped | The kill switch tripped. Find out why (Billing -> Reports), then re-link billing. Do not just re-link and forget. |
| Cloud Build `429` from Docker Hub | Builds pull base images anonymously. Use `FROM mirror.gcr.io/library/<image>` for official images. |
| Cloud Build GitHub connection rejects the token | It must be a classic personal access token; fine-grained tokens are not accepted. After renewing, add a new secret version and bump `github_token_secret_version`. |
| Egress is near the 1 GB limit | See the egress table in the design notes; the biggest levers are the monitor interval (keep 600 s or more) and `SYNC_PERIOD`. |
| `tofu apply` in CI says the plan is stale | The state changed after the plan was made. Push again or re-run the main workflow, then apply. |
| `zone must be inside region` | `GCP_ZONE` does not belong to `GCP_REGION`: set both consistently, re-run `bootstrap.sh`. |

## Security notes

- **Secret:** anything in a stack's `.env` on the VM (git token, Kuma password, ntfy token), `*.tfvars` files, the GitHub token of the build farm
  (Secret Manager). **Not secret:** project id, billing account id, repository id, service account e-mails, the Actions variables. Do not publish them anyway.
- **The OpenTofu state may contain secrets.** It lives in a private (public access prevented), versioned bucket in your project. The `tf-plan` identity can write
  that bucket too (OpenTofu needs it for locks), so anything that runs as `tf-plan` (any branch or pull request workflow of your repository) can alter or delete state;
  versioning keeps 10 versions. Never copy a state file around.
- **Trust rules:** only tokens of YOUR repository (matched by numeric id) are accepted. `tf-apply` is bound to the manual `workflow_dispatch` event on
  `refs/heads/main`. Fork pull requests get no secrets and no OIDC token.
- **Saved plans** (`tfplan-<sha>`, 7 days) and plan comments may contain sensitive values: another reason for a private repository.
- **Open ports:** SSH only from Google's IAP range (35.235.240.0/20) to VMs tagged `iap-ssh`; UDP 41641 over IPv6 for Tailscale (switch off with
  `enable_tailscale_direct_ipv6 = false`); everything else is the VPC's implicit deny. The VM has no IPv4 address.
- **The kill switch has billing rights on the project** (`roles/billing.projectManager` on this project only). The VM's own service account has no project roles.
- Container images float on `:latest` by default (`.env` variables let you pin tags); GitHub Actions are pinned to commit SHAs.

Report a vulnerability: [SECURITY.md](SECURITY.md).

## CI safety: pull requests from forks

- The workflow never uses `pull_request_target` or `workflow_run`.
- The `plan` job is the only job that logs in to Google on a pull request, and it is skipped unless the pull request's head repository is this repository
  (`.github/workflows/tofu.yml`). Fork pull requests run only formatting, validation, tflint, trivy and the offline tests, with no credentials.
- `tf-apply` can be used only by a `workflow_dispatch` run on `refs/heads/main` of your repository (the Workload Identity condition checks the numeric repository id, the ref and the event),
  and the apply job refuses to run from any other ref. `bootstrap/` is applied only from your laptop.

## Checks (the same run in CI)

```bash
tofu fmt -check -recursive
for d in bootstrap infra; do tofu -chdir=$d init -backend=false -lockfile=readonly && tofu -chdir=$d validate; done
tflint --init && tflint --recursive
trivy config .
shellcheck patch/*.sh scripts/*.sh stacks/*/*.sh
(cd patch && python3 -m unittest test_patch_agent)
(cd bootstrap/killswitch && python3 -m unittest test_main)
gitleaks detect --redact --no-banner
```

## Layout

```
bootstrap/   run once from your laptop (scripts/bootstrap.sh): state bucket, Workload Identity, budgets, kill switch, build-farm IAM
infra/       applied by CI: network, VM, patching, Cloud Build triggers
stacks/      Docker stack the VM can start (kuma): only when you create its .env
scripts/     preflight.sh (read-only checks), bootstrap.sh
cloudbuild/  amd64.yaml, inlined into every trigger
patch/       OS patching agent (offline tests)
docs/        CONFIGURATION.md (every variable), WHAT-YOU-DO.md (every manual step in order), DESIGN.md, BUILD-FARM.md, RECIPES.md, CHANGELOG.md
```

Some files mention a home server, a Gogs mirror and a "ChatOps" assistant: optional integrations of the original author's own setup (recipe 3).

## License and contributing

MIT, see [LICENSE](LICENSE). [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md).
