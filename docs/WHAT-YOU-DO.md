# What you do, in order

Manual steps for this repo. Commands run from the root of YOUR private copy
(called `~/gcp-always-free` below) on your laptop, signed in with
`gcloud auth login` and `gcloud auth application-default login`, unless a
step says otherwise. `<project-id>` and `<billing-account-id>` are the same
values you gave `scripts/bootstrap.sh` the first time. `<your-...>` always means a value of yours (`<your-zone>` is
`us-east1-b` unless you set `GCP_ZONE`); docs/CONFIGURATION.md lists every variable and `./scripts/preflight.sh` checks them
before you start. Sections B and C describe optional integrations of the original author's setup (a Cloud Build farm for a
cluster, a monitors repository on a home server): skip them unless you have the same.

## A. Laptop and first bootstrap

### A1. Install OpenTofu (once)

OpenTofu replaced Terraform in this repo on 2026-11-06: every command is
`tofu ...`, the `terraform` binary is no longer used (you can keep it
installed; nothing here calls it).

1. In WSL, install it from OpenTofu's own apt repository (the official
   installer, Debian/Ubuntu method). It asks for your sudo password:
   ```bash
   cd /tmp
   curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
   chmod +x install-opentofu.sh
   ./install-opentofu.sh --install-method deb
   rm -f install-opentofu.sh
   cd -
   ```
   Updates then come with `sudo apt update && sudo apt upgrade`.
2. Check: `tofu version` prints `OpenTofu v1.13.x` or newer (CI uses 1.13.9;
   the code needs at least 1.12.0).
3. If you ever ran `terraform init` in this repo, delete the old provider
   downloads once (they came from registry.terraform.io):
   `rm -rf bootstrap/.terraform infra/.terraform`. The next `tofu init`
   fetches them from registry.opentofu.org and checks them against the
   committed `.terraform.lock.hcl` files.

### A2. First bootstrap (once)

1. Create the private GitHub repo and push (bootstrap reads its id):
   `gh repo create <your-github-user>/gcp-always-free --private --source . --push`
2. Sign in to Google (two browser windows open; pick your account in both):
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```
3. Run the bootstrap with your project id and billing account id
   (console -> **Billing** -> **Account management**, "Billing account ID"):
   ```bash
   ./scripts/bootstrap.sh <project-id> <billing-account-id>
   ```
   OpenTofu shows its plan; type `yes`. It creates the state bucket, moves
   its own state into it, writes the bucket name into `infra/backend.tf` and
   sets the Actions variables `GCP_PROJECT_ID`, `WIF_PROVIDER`, `PLAN_SA`,
   `APPLY_SA`, `VM_SA_EMAIL`.
4. Commit the two backend files (by name) and push:
   ```bash
   git status --short     # bootstrap/backend.tf and infra/backend.tf
   git add bootstrap/backend.tf infra/backend.tf
   git commit -m "chore: set state bucket" && git push
   ```
5. GitHub -> <your-github-user>/gcp-always-free -> **Actions** -> **tofu**: wait for the
   run of your push to go green, then **Run workflow** -> branch `main` ->
   type `apply` -> **Run workflow** (creates the VM).

## B. Build farm (Cloud Build amd64 -> Artifact Registry -> cluster)

How it works: [BUILD-FARM.md](BUILD-FARM.md). Do these after the first
bootstrap (A2) worked. B1-B6 are once; B7 is per app.

### B1. Apply the build-farm part of bootstrap

```bash
./scripts/bootstrap.sh <project-id> <billing-account-id>
```

Read the plan OpenTofu shows: it adds 3 APIs, the Artifact Registry repo
`images` (us-central1), the service accounts `cloud-build-amd64` and
`ar-pull-cluster`, the empty secret `cloudbuild-github-token` and a few IAM
members for `tf-plan` / `tf-apply`. Type `yes`.

If it fails on `google_secret_manager_secret_iam_member.github_token_cloudbuild`
with "service account ... does not exist": Google creates the Cloud Build
service agent a minute after the API is enabled. Wait a minute and run the
same command again.

Then note the values for later:

```bash
tofu -chdir=bootstrap output -raw images_registry    # us-central1-docker.pkg.dev/<project-id>/images
tofu -chdir=bootstrap output -raw ar_pull_sa_email   # ar-pull-cluster@<project-id>.iam.gserviceaccount.com
```

### B2. Create the GitHub token for the connection

Cloud Build only accepts a **classic** token (not fine-grained).

1. github.com -> your avatar -> **Settings** -> **Developer settings** ->
   **Personal access tokens** -> **Tokens (classic)** -> **Generate new token**
   -> **Generate new token (classic)**.
2. Note: `cloud-build-connection`. Expiration: your choice (write the date in
   your calendar; on expiry, B6 shows how to replace it).
3. Scopes: tick **repo** (whole group) and **read:user** (under "user").
   Nothing else.
4. **Generate token**, copy it (shown once).

### B3. Put the token into Secret Manager

The token goes straight from your clipboard into Google; it never touches a
file or OpenTofu:

```bash
read -rs GH_TOKEN      # paste the token, press Enter (nothing is shown)
printf '%s' "$GH_TOKEN" | gcloud secrets versions add cloudbuild-github-token \
  --project <project-id> --data-file=-
unset GH_TOKEN
```

It prints `Created version [1] of the secret [cloudbuild-github-token]`. The
`1` is what `github_token_secret_version` expects (its default).

### B4. Install the Cloud Build GitHub App

1. Open https://github.com/apps/google-cloud-build -> **Install** (or
   **Configure** if it is installed already).
2. Pick the account **<your-github-user>**.
3. **Only select repositories** -> select every repo you will build (you can
   add more later the same way) -> **Install**.
4. GitHub may forward you to a Google Cloud page; close it, nothing to do
   there.
5. Find the installation ID: github.com -> **Settings** -> **Applications** ->
   tab **Installed GitHub Apps** -> **Google Cloud Build** -> **Configure**.
   The address bar now ends in `/settings/installations/12345678`: that
   number is the installation ID.

### B5. Turn the triggers on (PR + manual apply)

1. `git switch -c build-farm`
2. Edit `infra/cloudbuild-settings.tf`:
   - `github_app_installation_id`: `default = 0` -> `default = <the number from B4>`
   - `build_repos`: add your first repo, e.g.
     ```hcl
     default = {
       "photo-sweep" = {}
     }
     ```
     (`{ image = "api", dockerfile = "docker/Dockerfile", context = "." }` when
     the image name or paths differ from the defaults.)
3. `git add infra/cloudbuild-settings.tf && git commit -m "feat: build farm on" && git push -u origin build-farm`,
   open the PR.
4. Read the plan comment: `google_cloudbuildv2_connection.github[0]`, one
   `google_cloudbuildv2_repository.build["<repo>"]` and two
   `google_cloudbuild_trigger.amd64[...]` (`.../main`, `.../tag`) to add,
   nothing to destroy.
5. Merge. Wait for the `tofu` run on main to pass (Actions tab).
6. Actions -> **tofu** -> **Run workflow** -> branch `main` -> type
   `apply` -> **Run workflow**.
7. Check in the console: **Cloud Build** -> **Repositories** -> tab **2nd gen**:
   connection `github` (region us-central1) with a green tick and your repo
   under it. **Cloud Build** -> **Triggers** (region us-central1):
   `amd64-<repo>-main` and `amd64-<repo>-tag`.
   If the connection shows an error about the token: the token lacks `repo`
   or `read:user`, or B3 stored a different version number.

### B6. First build and the cluster's pull key

1. Start a build without pushing: **Cloud Build** -> **Triggers** ->
   `amd64-<repo>-main` -> **Run** -> branch `main` -> **Run trigger**.
   **History** shows it; 1-10 minutes.
2. Check the image:
   ```bash
   gcloud artifacts docker images list us-central1-docker.pkg.dev/<project-id>/images --include-tags
   ```
   One line with tags `<commit sha>, latest`.
3. Continue in the k8s-free-gitops repo: `~/k8s-free-gitops/docs/WHAT-YOU-DO.md`
   step 18. Its step 18.3 makes the cluster's read-only key of
   `ar-pull-cluster` (`gcloud iam service-accounts keys create /tmp/ar-pull.json ...`),
   seals it and deletes the file. One key is enough; list keys with
   `gcloud iam service-accounts keys list --iam-account ar-pull-cluster@<project-id>.iam.gserviceaccount.com --managed-by user`
   and delete extra ones with `gcloud iam service-accounts keys delete <key-id> --iam-account ...`.
   If the key command fails with `constraints/iam.disableServiceAccountKeyCreation`,
   your account sits in an organisation that blocks keys: IAM & Admin ->
   Organization Policies -> "Disable service account key creation" ->
   override for this project -> Not enforced, then retry.
4. Replacing the GitHub token later (B2 again, then):
   ```bash
   read -rs GH_TOKEN; printf '%s' "$GH_TOKEN" | gcloud secrets versions add cloudbuild-github-token --project <project-id> --data-file=-; unset GH_TOKEN
   ```
   Set `github_token_secret_version` in `infra/cloudbuild-settings.tf` to the
   new number, PR, apply. Then destroy the old version so it does not count
   against the 6 free versions:
   `gcloud secrets versions destroy <old number> --secret cloudbuild-github-token --project <project-id>`.

### B7. Each new app (any time)

1. GitHub App: B4 steps 1-3, add the repo.
2. `build_repos` in `infra/cloudbuild-settings.tf`: add `"<repo>" = {}`;
   PR, read the plan (+1 repository, +2 triggers), merge, apply (B5 steps 3-6).
3. Cluster repo: add the image to `infrastructure/registry/multiarch/images.yaml`
   (its docs/WHAT-YOU-DO.md steps 18.4 and 18.5).

### B8. Keep an eye on it (monthly, 2 minutes)

- **Billing** -> **Reports** -> group by **Service**: Cloud Build and
  Artifact Registry should show usage but cost 0 (except a few cents of
  Artifact Registry network egress, see BUILD-FARM.md "Free limits").
- **Artifact Registry** -> `images` -> the repo size (top right) stays under
  0.5 GB. If not, lower `images_keep_count` in `bootstrap/cloudbuild.tf` and
  run B1 again.

## C. Kuma on the VM (IPv6 only, location `gcp`) (OPTIONAL, original author's setup)

What it is: README "Kuma on the VM". Do these after the first VM apply.
C2 needs Oracle's micro-edge running and the Home side ready (oracle-always-free
docs/WHAT-YOU-DO.md steps 12 and 13).

### C1. Apply the IPv6-only VM

1. Merge the change (or push to main), wait for the plan run to finish green.
2. GitHub -> <your-github-user>/gcp-always-free -> **Actions** -> **tofu** -> **Run
   workflow** -> branch `main` -> type `apply` -> **Run workflow**.
3. The plan shows the subnet becoming dual-stack (in place), a new firewall
   rule `allow-tailscale-ipv6`, and the VM without an IPv4 access config and
   with an IPv6 one (if the VM already exists, OpenTofu stops it for that,
   or replaces it: the plan says which). The output `external_ipv6` is the
   VM's only public address.

### C2. Values you need ready

From oracle-always-free docs/WHAT-YOU-DO.md step 13 (keep them in your password
manager, never in chat or git):
- a second Gogs token of user `kuma-sync`, named `kuma-gcp`;
- the git URL `https://kuma-home.<tailnet name>/<your Gogs user>/self-hosted.git`;
- `KUMA_WORKER_URL` and `KUMA_TOKEN`;
- the push URL `https://kuma-home.<tailnet name>/api/push/<KUMA_PUSH_TOKEN_GCP>`.

### C3. Fill in the stack's .env on the VM

1. `gcloud compute ssh free-vm --zone <your-zone> --tunnel-through-iap`
2. Check the startup script installed the stack:
   `ls /opt/stacks/kuma` shows `docker-compose.yml`, `up.sh` and friends.
   (If not: `sudo journalctl -u google-startup-scripts --no-pager | tail -40`.)
3. Create the .env:
   ```bash
   cd /opt/stacks/kuma
   sudo cp .env.example .env && sudo chmod 600 .env && sudo nano .env
   ```
   Fill in `KUMA_ADMIN_USER` (e.g. `admin`), `KUMA_ADMIN_PASSWORD` (make one
   with `openssl rand -base64 24`), `GIT_URL`, `GIT_USERNAME=kuma-sync`,
   `GIT_TOKEN` (the `kuma-gcp` token), `KUMA_WORKER_URL`, `KUMA_TOKEN`,
   `KUMA_PUSH_URL` (C2). Leave `TS_AUTHKEY` empty and keep
   `AUTOKUMA_IMAGE=localhost:5000/...` and `COMPOSE_PROFILES=ghcr-mirror`.
   Save (Ctrl+O, Enter, Ctrl+X).

### C4. Start it and log in to Tailscale

1. `sudo ./up.sh`. The first time it stops with "Tailscale is not logged in".
2. `sudo docker compose logs tailscale | grep login.tailscale.com`, open the
   link in your browser, log in with your Tailscale account.
3. `sudo ./up.sh` again. It pulls AutoKuma through micro-edge (first pull
   takes a minute) and starts everything; the last lines list the containers.
4. Tailscale admin console -> **Machines** -> `kuma-gcp` -> **...** ->
   **Disable key expiry**.

From now on every reboot runs `up.sh` by itself (startup script).

### C5. Create the Kuma admin account

1. From a device on your tailnet open `https://kuma-gcp.<tailnet name>` (the
   first load can take a minute while the certificate is issued).
2. Create the admin account with exactly `KUMA_ADMIN_USER` /
   `KUMA_ADMIN_PASSWORD` from the .env.
3. Close the tab when done: every page load costs 1-3 MB of the 1 GB free
   egress (README "Egress budget").

### C6. Check it works

On the VM, in `/opt/stacks/kuma`:
- `sudo docker compose logs sync` -> "8 file(s) updated from commit ..."
  (plus 1 for the notification);
- `sudo docker compose logs autokuma` -> "Created Monitor ..." lines;
- `sudo docker compose logs push` -> no lines is good.

In the Home Kuma, the push monitor "Kuma gcp" turns green within 2 minutes.

### C7. The hard USD 1 cap is live (nothing to switch on)

The bootstrap deploys the cap live (README "Hard USD 1 cap"). Check once that
it exists: Console -> **Cloud Run** -> `billing-kill-switch` is there, and
the budget's Pub/Sub topic is attached (Billing -> Budgets & alerts).
If it ever trips (VM stopped, builds fail with a billing error): Billing ->
**Account management** -> link the project again, then look at Billing ->
Reports to see what cost money before it trips again.
To only log instead: in `bootstrap/variables.tf` set the default of
`kill_switch_dry_run` to `true` and run `./scripts/bootstrap.sh <project-id>
<billing-account-id>` again. (Not in `terraform.tfvars`: the script rewrites
it every run.)

### C8. Watch the egress (monthly, 2 minutes)

Console -> **Billing** -> **Reports** -> Group by **SKU**, this month,
filter Service **Compute Engine**: the "Network Internet Data Transfer Out"
SKUs together should stay under 1 GB (estimate about 0.76 GB). If they do
not, see README "Egress budget" for what to cut.

### C9. Updating the stack later

Edit `stacks/kuma/` (and the same file in oracle-always-free `stacks/micro-kuma/`),
PR, merge, apply: the new files go into the VM's startup script. Then on the
VM: `sudo google_metadata_script_runner startup` (or reboot). `sudo
/opt/stacks/kuma/up.sh` alone pulls newer images (floating tags).

## D. OS patching (the VM patches itself)

Updates are installed by **Google VM Manager** (a weekly patch deployment, Tuesday
22:00 UTC, free for up to 100 VMs per billing account; set `patch_installer =
"unattended"` to use apt's unattended-upgrades instead); nothing reboots
by itself (mode `alert`, your pick in the checklist: reminder every 3 days
while a reboot waits, you reboot with ChatOps `reboot free-vm <code>`). Design,
secrets and the other machines: `patch/README.md`. Do this on the **Google VM
first**: it is the least risky machine.

### D1. Apply the change (once)

1. Merge the pull request, then run the manual apply (Actions -> tofu -> Run
   workflow -> type `apply`). Only the VM's startup-script metadata changes: no
   rebuild, no stop.
2. On the VM, run the startup script once (it installs the agent and the timers):
   ```bash
   gcloud compute ssh free-vm --zone <your-zone> --tunnel-through-iap \
     --command 'sudo google_metadata_script_runner startup'
   ```
   The last lines say `patching on free-vm: installer osconfig, mode alert, changes applied` and
   `NEXT: put the three secret values in /etc/patch-agent.env`.
   (Without Terraform: `gcloud compute scp patch/patch-agent patch/apply-patching.sh
   free-vm:/tmp/ --zone <your-zone> --tunnel-through-iap`, then on the VM
   `sudo bash /tmp/apply-patching.sh --host free-vm --day wed --kuma yes --containers
   "kuma_tailscale kuma_app kuma_autokuma kuma_sync kuma_push" --ts-container
   kuma_tailscale --push-container kuma_push`.)

### D2. The three secret values

Names only here, values from <home-server-repo> (`ops/patch/README.md`, "Secrets"):
`PATCH_NTFY_URL`, `PATCH_ALERT_URL`, `PATCH_HEARTBEAT_URL`.

```bash
gcloud compute ssh free-vm --zone <your-zone> --tunnel-through-iap
sudoedit /etc/patch-agent.env      # fill the three names, save
sudo patch-agent report            # last line should end with: feed
sudo patch-agent status
exit
```

Then in the server topic: `patchstatus` lists `free-vm`.

### D3. First check

`sudo systemctl list-timers 'patch-*'` shows the report timer and the approval
timer. Reboot test, when it suits you: ChatOps `reboot free-vm <code>` (it
reboots within 10 minutes only if a reboot is waiting). After it,
the server topic says `free-vm is back`. If something is missing after a boot, an ntfy alert names the machine.

