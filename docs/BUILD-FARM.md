# Build farm: one image tag, two architectures

Every app image exists for linux/amd64 (the Home server) and linux/arm64
(the Oracle cluster) under ONE tag in Zot, the cluster's registry:

```
git push main / git tag  (GitHub, repo listed in build_repos)
   |
   v
Cloud Build trigger amd64-<repo>-main / amd64-<repo>-tag      (this repo)
   runs cloudbuild/amd64.yaml as cloud-build-amd64, e2-standard-2, us-central1
   docker build --platform linux/amd64
   push  us-central1-docker.pkg.dev/<project>/images/<image>:<commit sha> + :latest   (main)
         us-central1-docker.pkg.dev/<project>/images/<image>:<git tag>                (tag)
   label org.opencontainers.image.revision=<commit sha>
   |
   v
CronJob multiarch/multiarch, every 20 min       (k8s-free-gitops repo, infrastructure/registry/multiarch)
   plan   for each image in images.yaml: the commit behind :latest + every git tag
   build  arm64 on the cluster's rootless BuildKit, source = GitHub at that commit
          -> zot.zot.svc.cluster.local:5000/<image>:<tag>-arm64
   join   when BOTH exist: copy amd64 -> Zot <image>:<tag>-amd64,
          write the index Zot <image>:<tag> = amd64 + arm64,
          move Zot <image>:latest to the newest joined commit
   |
   v
Home (amd64):  docker pull zot.<tailnet>.ts.net/<image>:latest      (tailnet)
cluster (arm64):  image: localhost:30500/<image>:latest                 (NodePort)
```

The same tag resolves to the right architecture on each side. Artifact
Registry is only the hand-over point: it keeps the newest few versions and
deletes the rest; Zot keeps everything (its blobs are in Oracle Object
Storage).

## Where things live

| Piece | File | Applied by |
|---|---|---|
| APIs (Artifact Registry, Cloud Build, Secret Manager) | `bootstrap/cloudbuild.tf` | you, `scripts/bootstrap.sh` |
| Artifact Registry repo `images` (us-central1) + cleanup policy | `bootstrap/cloudbuild.tf` | you |
| Service account `cloud-build-amd64` (builds run as it): push to `images`, write logs | `bootstrap/cloudbuild.tf` | you |
| Service account `ar-pull-cluster`: read-only on `images` (the cluster's key) | `bootstrap/cloudbuild.tf` | you |
| Secret `cloudbuild-github-token` (empty; you add the GitHub token as a version) | `bootstrap/cloudbuild.tf` | you |
| Extra roles for CI: `tf-plan` connectionViewer + builds.viewer, `tf-apply` connectionAdmin + builds.editor + actAs on `cloud-build-amd64` | `bootstrap/cloudbuild.tf` | you |
| Settings: installation ID, `build_repos` | `infra/cloudbuild-settings.tf` | CI (PR -> plan, manual apply) |
| 2nd-gen GitHub connection `github`, one linked repo per entry, two triggers per repo | `infra/cloudbuild.tf` | CI |
| The build itself | `cloudbuild/amd64.yaml` (inlined into every trigger) | CI |
| Join, arm64 build, image list, pull key | `k8s-free-gitops` repo, `infrastructure/registry/multiarch/` | Flux |

Why two halves: CI's `tf-apply` can only change compute resources plus what
the Cloud Build triggers need. Creating service accounts, granting IAM and
enabling APIs stays with your own account in `bootstrap/`, like the VM's
service account. Nothing in `infra/cloudbuild.tf` exists until
`github_app_installation_id` is set, so CI keeps working before you start.

## Adding an app

1. Here: add `"<repo>" = {}` to `build_repos` in `infra/cloudbuild-settings.tf`
   (or `{ image = "...", dockerfile = "docker/Dockerfile", context = "." }`).
   The GitHub App must have access to the repo (WHAT-YOU-DO step B4).
   PR, read the plan (1 linked repo + 2 triggers), merge, run the apply.
2. In `cluster`: add `<image> <your-github-user>/<repo> [dockerfile] [context]` to
   `infrastructure/registry/multiarch/images.yaml` (same image name). If the
   repo is private, the token in `multiarch-creds` must cover it.
3. Push to main. About 2-5 minutes later the amd64 image is in Artifact
   Registry; within 20 minutes more the cluster has built arm64 and joined
   both. Check: `regctl manifest get zot.<tailnet>.ts.net/<image>:latest`
   lists `linux/amd64` and `linux/arm64`.

## Tags and how the join decides

- Cloud Build: push to main -> `:<full commit sha>` and `:latest`; a git tag
  -> `:<tag>`. Both carry the label `org.opencontainers.image.revision`.
- The cluster job looks at two kinds of tags per image: the commit sha that
  `:latest` was built from (read from that label) and every git tag. Older
  commit tags in Artifact Registry are ignored: they are about to be deleted
  by the cleanup policy, and copying them would only cost egress.
- arm64 is built only when Zot has no `<tag>-arm64` built from the same
  commit (max 2 builds per run). With `-` instead of a repo in
  `images.yaml` the job never builds and waits for someone to push
  `<image>:<tag>-arm64` to Zot.
- The index `<image>:<tag>` is written only when both `<tag>-arm64` (Zot) and
  `<tag>` (Artifact Registry) exist and are really linux/arm64 and
  linux/amd64. If the index already lists exactly those two digests, nothing
  happens. That makes every run idempotent.
- `<image>:latest` in Zot moves to the index of the newest commit once that
  commit is joined, never earlier: Zot's `:latest` is always a complete
  two-architecture image.

## Free limits (checked 2026-11-06)

| Service | Free | After that | Source |
|---|---|---|---|
| Cloud Build | 2,500 build-minutes/month per billing account, e2-standard-2 in the default pool ("promotional free tier ... subject to change") | USD 0.006/minute | https://cloud.google.com/build/pricing |
| Artifact Registry storage | 0.5 GiB/month per billing account (all projects together) | USD 0.10/GiB-month | https://cloud.google.com/artifact-registry/pricing |
| Artifact Registry data transfer | free inside the same region (Cloud Build -> registry); NO free allowance to the internet | Premium Tier internet rates (about USD 0.12/GiB for the first TiB from North America, more to some destinations) | https://cloud.google.com/artifact-registry/pricing, https://cloud.google.com/vpc/network-pricing |
| Secret Manager | 6 active secret versions, 10,000 access operations, 3 rotation notifications per month (automatic replication counts as one location) | USD 0.06/version-month | https://cloud.google.com/secret-manager/pricing |
| Cloud Logging (build logs) | 50 GiB/project/month | | https://cloud.google.com/free/docs/free-cloud-features |
| Service accounts, IAM, triggers, the connection | free | | |

What that means here:

- **Build minutes**: a small image takes 1-3 minutes, a large one 5-10. 2,500
  minutes is several hundred builds a month. Cloud Build -> History shows
  each build's duration.
- **Storage**: `images_keep_count` (default 3) versions per image stay; a
  cleanup run (about daily) deletes everything older than a day beyond those
  and every untagged version. 3 versions of a ~150 MB image fit; with several
  big images lower `images_keep_count` in `bootstrap/cloudbuild.tf` (re-run
  bootstrap). Shared base layers are stored once.
- **Egress is the one real cost**: the cluster in Johannesburg pulls each
  joined amd64 image out of Google Cloud. Only layers Zot does not have yet
  travel (base layers once, then the changed app layers), and only `:latest`
  and git tags are copied, not every commit. Expect cents per month; a
  monthly 1 GB would be roughly USD 0.12-0.15. It counts toward the
  "beyond free tier" budget and the kill switch (USD 1, live).
- **Home pulls from Zot, not from Artifact Registry**, so its pulls cost
  nothing on the Google side (Oracle's outbound transfer is free up to
  10 TB/month).

## Limits and things not tested live

- Nothing here has run yet (no GCP connection, no cluster). Unknowns: the
  connection accepting the token with a numbered secret version (it is the
  documented format), BuildKit fetching a private repo with
  `GIT_AUTH_TOKEN`, regctl against Zot over plain HTTP. The plan/build/join
  scripts were tested against local OCI layouts with a fake buildctl.
- Cloud Build pulls base images anonymously from Docker Hub; if builds fail
  with HTTP 429, use `FROM mirror.gcr.io/library/<image>` for official images.
- A Dockerfile that only builds on amd64 fails the arm64 build; the job logs
  it, fails, and retries every run until a new commit fixes it. Suspend the
  CronJob meanwhile if BuildKit load matters.
- The GitHub token for the connection must be a classic token (Cloud Build
  does not accept fine-grained tokens). When it expires, add a new secret
  version and bump `github_token_secret_version`.
