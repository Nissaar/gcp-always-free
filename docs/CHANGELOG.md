# Changelog

Notable changes of this public copy, newest first. Changes that need a manual step from you are marked **ACTION**.

## 2026-11-25: audit for strangers, variables, preflight

### Security
- **The shipped backend files no longer point at somebody else's state bucket.** `bootstrap/backend.tf` is not shipped (the first bootstrap writes it;
  a shipped copy made the script skip the first run), `infra/backend.tf` carries a `<your-project-id>-tfstate` placeholder that `scripts/bootstrap.sh` replaces.
- `github_owner` (build farm) has no default owner any more; the build farm refuses to turn on without it.
- Validation on every identifier you give: project id, billing account id (the all-zeros example is refused), repository, numeric repository id,
  service account e-mail, zone inside region, kill-switch thresholds.
- Workflow: `persist-credentials: false` on every checkout, `timeout-minutes` on every job, optional `GCP_REGION` / `GCP_ZONE` variables, wider shellcheck.
- The Tailscale firewall rule (UDP 41641 over IPv6) can be switched off with `enable_tailscale_direct_ipv6 = false`.

### Added
- `docs/CONFIGURATION.md`: every variable, where it is set, default, example.
- `scripts/preflight.sh`: read-only check of tools, variables, files, Google and GitHub logins, the project and its billing link, repository settings.
- `scripts/bootstrap.sh` takes `GCP_REGION` and `GCP_ZONE`, validates its arguments and sets the matching Actions variables.
- Image variables for the Kuma stack (`TAILSCALE_IMAGE`, `KUMA_IMAGE`, ...).
- README: how a stranger uses the repository, step by step.

### Changed
- The Kuma stack's `.env.example` describes a generic git source instead of the original author's mirror (the stack still only starts when you create `.env`).

