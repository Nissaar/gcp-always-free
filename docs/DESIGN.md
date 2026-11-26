<!-- Design notes of the original private repository, kept as the technical reference. The README is the entry point. -->

> Design notes. Regions, names and sizes mentioned here are the original author's examples; the values you set are listed in
> [CONFIGURATION.md](CONFIGURATION.md) and the README says what to do.

# gcp-always-free

One always-free Google Cloud VM (e2-micro), managed with OpenTofu and deployed
by GitHub Actions with a manual apply step.

## What gets built

| Piece | Where | Free? |
|---|---|---|
| e2-micro VM, Debian 13, 30 GB `pd-standard` disk, us-east1-b | `infra/vm.tf` | Yes (free tier: 1 e2-micro + 30 GB standard disk per billing account) |
| External IPv6 only (dual-stack subnet, Premium tier), no external IPv4 | `infra/vm.tf`, `infra/network.tf` | Yes: external IPv6 addresses are not charged; an external IPv4 would be about USD 3.65/month |
| Egress | | 1 GB/month free (Premium tier, North America to anywhere but China/Australia). Estimate below: about 0.7 GB |
| Custom VPC, SSH only through IAP, inbound UDP 41641 over IPv6 for Tailscale, all else blocked | `infra/network.tf` | Yes |
| Docker, the Kuma stack (`stacks/kuma/`), automatic security updates, no swap | `infra/startup.sh.tftpl` | Yes |
| OS patching: Google VM Manager patch deployment (free, no auto reboot), patch agent, post-boot check, reboot reminders (`patch/README.md`) | `patch/`, `infra/startup.sh.tftpl`, variables `patch_reboot_mode`, `patch_installer`; `infra/patch-deployment.tf` | Yes |
| State bucket (versioned, US-EAST1) | `bootstrap/` | Yes (5 GB free) |
| Keyless GitHub -> GCP auth (Workload Identity Federation) | `bootstrap/` | Yes |
| Budget alert: anything this project costs beyond the free tier | `bootstrap/` | Yes |
| Budget alert: how much of the USD 300 trial credit is used | `bootstrap/` | Yes |
| Hard cap: billing detached when spend beyond the free tier passes USD 1 (`enable_billing_kill_switch`, on and live) | `bootstrap/killswitch.tf` | Yes (Pub/Sub, Cloud Run functions, Cloud Build free tiers) |

Settings that keep the VM free (machine type, disk type, network tier, region)
are fixed in code or validated, so a typo cannot quietly start billing.

## Pipeline

```
PR            validate (fmt, validate, tflint) + trivy  ->  plan  ->  plan posted on the PR
push to main  validate + trivy  ->  plan  ->  plan saved as an artifact (7 days)
manual        Actions -> tofu -> Run workflow (main), type "apply"
              -> applies exactly the plan saved for the current main commit
```

- **Two GCP identities.** `tf-plan` can only read compute resources (any branch or
  PR may use it). `tf-apply` can change them, and GCP only lets a token from a
  `workflow_dispatch` run on `refs/heads/main` of this repo use it. No JSON keys anywhere.
- **Why apply is a manual run and not an approval button.** GitHub only offers
  required reviewers on environments for public repos (or Enterprise). This repo is
  private on the Free plan, so "manual apply" means a run you start yourself.
- **Stale plans are refused.** If anything changed the state after the plan was
  made, OpenTofu rejects the apply; push again or re-run the main workflow.
- All actions are pinned to commit SHAs (trivy-action tags were hijacked in
  March 2026, CVE-2026-33634). Renovate keeps them and the OpenTofu/Trivy/tflint
  versions up to date.

## First-time setup

OpenTofu (`tofu`) on the laptop first: docs/WHAT-YOU-DO.md step A1.

```bash
gcloud auth login
gcloud auth application-default login
./scripts/bootstrap.sh <project-id> <billing-account-id>
git add bootstrap/backend.tf infra/backend.tf && git commit -m "chore: set state bucket" && git push
```

`bootstrap.sh` enables the APIs, creates everything in `bootstrap/`, moves its
state into the bucket and sets these GitHub Actions variables:
`GCP_PROJECT_ID`, `WIF_PROVIDER`, `PLAN_SA`, `APPLY_SA`, `VM_SA_EMAIL`.
Then run the workflow manually (type `apply`) to create the VM.

## Using the VM

```bash
gcloud compute ssh free-vm --zone us-east1-b --tunnel-through-iap
```

OS Login is on, so access follows your Google account's IAM roles; no SSH keys
to manage. IAP reaches the VM on its internal IPv4, so SSH works without a
public IPv4. The VM has 2 shared vCPUs (bursting) and 1 GB RAM, no swap (your
rule): every container in the stack has a memory cap.

## Changing or removing things

- Change: edit `infra/`, open a PR, read the plan comment, merge, run the apply.
- Destroy the VM: set `deletion_protection = false`, apply, then remove the
  resources from `infra/` (or `tofu destroy` locally with your own account).
- `bootstrap/` is never applied by CI. Re-run `scripts/bootstrap.sh` after editing it.

## Before the trial ends

When the 90 days or the USD 300 run out, Google stops resources and deletes
them 30 days later unless the billing account is upgraded to a paid account.
Upgrade (Billing -> Overview -> Upgrade) to keep the VM; after that only the
items marked "No" above are billed, and the "beyond free tier" budget emails you.

## Hard USD 1 cap

Budgets only send email. `bootstrap/killswitch.tf` adds Google's documented
cap: the "beyond free tier" budget publishes to Pub/Sub, and a small function
(`bootstrap/killswitch/main.py`) unlinks the billing account from this project
once spend passes the budget. Everything paid in the project then stops,
the VM included, until you re-link billing (Billing -> Account management).

It is on since the VM became IPv6-only (2026-11-06; a public IPv4, ~USD
3.65/month, counts as spend even while trial credit pays for it and would
trip it within a week). It is **live from the first bootstrap** (decided
2026-11-07; `kill_switch_dry_run` defaults to `false`). If it ever trips, the
build farm (Cloud Build, Artifact Registry) stops with the VM: re-link
billing (docs/WHAT-YOU-DO.md step C7) after finding out why. To only log
instead, set the default of `kill_switch_dry_run` to `true` in
`bootstrap/variables.tf` and re-run
`./scripts/bootstrap.sh <project-id> <billing-account-id>`. Change the
defaults, not `terraform.tfvars`: the script rewrites that file each run.

## Build farm (amd64 images)

Cloud Build turns every push to main and every tag of the repos in
`build_repos` (`infra/cloudbuild-settings.tf`) into a linux/amd64 image in
Artifact Registry (`us-central1-docker.pkg.dev/<project>/images`, cleanup
keeps it under the 0.5 GB free storage). The Oracle cluster builds the arm64
twin and joins both into one multi-arch tag in its Zot registry.

- `bootstrap/cloudbuild.tf`: APIs, the `images` repo + cleanup policy, the
  service accounts `cloud-build-amd64` (builds) and `ar-pull-cluster`
  (cluster pulls, read-only), the empty secret for the GitHub token, the
  roles CI needs. Applied by `scripts/bootstrap.sh`.
- `infra/cloudbuild.tf` + `infra/cloudbuild-settings.tf`: the 2nd-gen GitHub
  connection, linked repos and triggers. Applied by the normal pipeline;
  off while `github_app_installation_id = 0`.
- `cloudbuild/amd64.yaml`: the build, inlined into every trigger.

Flow, tags, free limits with sources: [docs/BUILD-FARM.md](BUILD-FARM.md).
Manual steps: [docs/WHAT-YOU-DO.md](WHAT-YOU-DO.md) section B.

## Kuma on the VM (location `gcp`)

The VM runs the third Uptime Kuma (the others: Home, Oracle micro-kuma).
`infra/startup.sh.tftpl` installs Docker from Debian and writes
`stacks/kuma/` to `/opt/stacks/kuma/` on every boot; your secrets go into
`/opt/stacks/kuma/.env` by hand (docs/WHAT-YOU-DO.md section C) and are never
in OpenTofu state or git. The stack is the same as oracle-always-free
`stacks/micro-kuma/` (keep both identical; only `.env.example` differs):

- `tailscale`: tailnet device `kuma-gcp`, kernel mode in its own network
  namespace, serves the Kuma UI on `https://kuma-gcp.<tailnet>.ts.net`.
- `kuma` (Uptime Kuma 2) + `autokuma`: monitors from
  `uptime-kuma/remote-monitors/gcp/` (all 33 public HTTPS monitors, 600 s, 2 retries of
  60 s). Checks go straight out over IPv6, never through the tailnet or
  an exit node, so they really test from the US.
- `sync`: git checkout of the self-hosted repo from the Gogs mirror on the
  Home server, over the tailnet (`kuma-home.<tailnet>.ts.net`), every
  10 minutes; also writes the `worker` webhook notification (alert-details
  Worker, `POST /kuma/gcp`).
- `push`: heartbeat to the Home Kuma's push monitor every 60 s over the
  tailnet, only while the local Kuma answers.
- `ghcr-forward`: AutoKuma is only published on ghcr.io (no IPv6). The VM's
  Docker pulls `localhost:5000/bigboot/autokuma:2`, forwarded over the tailnet
  to the ghcr.io pull-through cache on Oracle's `micro-edge`.

Memory caps add up to about 750 MB of the 1 GB.

## IPv6 only: what answers (checked 2026-11-06)

| Needed for | Host | IPv6? | Used how |
|---|---|---|---|
| Debian packages, Docker engine | deb.debian.org, security.debian.org (Fastly) | Yes | directly; apt forced to IPv6 |
| Docker Hub images (Kuma, Tailscale, alpine/git, curl, socat) | registry-1.docker.io, auth.docker.io, production.cloudflare.docker.com | Yes (GA since Aug 2023; the old `registry.ipv6.docker.com` beta name is retired) | directly |
| AutoKuma image | ghcr.io | **No** (no AAAA) | through micro-edge's cache over the tailnet |
| Git (self-hosted repo) | github.com | **No** | Gogs mirror on the Home server over the tailnet |
| Tailscale control, DERP relays | controlplane/login.tailscale.com, derp*.tailscale.com | Yes | directly; peers without IPv6 (Oracle micros) are reached through DERP |
| Alerts | alert-details.<sub>.workers.dev (Cloudflare) | Yes | directly |
| Kuma's checks | `*.example.com` behind Cloudflare | Yes | directly |

Docker 26 (Debian 13) needs `"experimental": true, "ip6tables": true` in
`/etc/docker/daemon.json` for IPv6 NAT on the dual-stack `kuma` network; the
startup script writes it. Docker's own pulls and every container prefer IPv6
and fall back fast.

## Egress budget (1 GB/month free)

Only traffic leaving the VM counts; image pulls and check responses are
incoming and free. Estimate for one month:

| What | Assumption | MB/month |
|---|---|---|
| Kuma checks | 33 monitors x one every 600 s = 142,560 checks; a fresh TLS handshake + request + TCP ACKs is about 3 KB sent per check | ~430 |
| Heartbeat to Home | 43,200 HTTPS requests over WireGuard/DERP, about 3.5 KB sent each | ~150 |
| Git sync | 4,320 fetches (every 10 min), about 8 KB sent each | ~35 |
| Tailscale control, DERP keepalives (log upload is off) | about 1 MB/day | ~30 |
| apt, image pulls, webhooks to the Worker | requests only | ~10 |
| Patching: daily status + heartbeat, reboot-approval check every 10 min to ntfy.sh | ~4,500 HTTPS requests, about 3 KB sent each (`--no-approvals` drops 13 MB) | ~14 |
| Opening the Kuma UI over the tailnet | 1-3 MB per page load, a few a month | ~15 |
| **Total** | | **~685** |

Levers if Billing shows more: each GCP monitor costs about 13 MB/month at
600 s (do not go below 600 s: 300 s would be about 860 MB for the checks alone;
the generator is <home-server-repo> `uptime-kuma/remote/build_remote.py`),
`SYNC_PERIOD=1800` saves about 25 MB, and keep the Kuma UI closed. Do not
raise `PUSH_PERIOD` above 60: the Home push monitor expects one per minute.
Standard network tier would give 200 GiB, but external IPv6 on Standard tier
is still Preview, so this uses Premium (the spec's choice).
