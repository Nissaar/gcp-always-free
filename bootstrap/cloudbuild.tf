# Build farm, part 1 of 2 (docs/BUILD-FARM.md): the pieces that need the
# project owner, so they live here and are applied by scripts/bootstrap.sh
# with your own account, never by CI.
#
#   - APIs: Artifact Registry, Cloud Build, Secret Manager
#   - Artifact Registry docker repo "images" (us-central1) with a cleanup
#     policy that keeps it under the 0.5 GB free storage
#   - service account cloud-build-amd64: what the builds run as (push to
#     "images", write build logs, nothing else)
#   - service account ar-pull-cluster: read-only on "images"; the Oracle
#     cluster pulls with a key of it (made by hand, never in OpenTofu state)
#   - secret cloudbuild-github-token: an EMPTY container. You add the GitHub
#     token as a version yourself (docs/WHAT-YOU-DO.md), so the token never
#     passes through OpenTofu or its state
#   - the extra roles tf-plan / tf-apply need to manage part 2 (the GitHub
#     connection and the triggers in infra/cloudbuild.tf) from CI
#
# Everything here is free: the repo is empty until a build pushes, service
# accounts and IAM cost nothing, one active secret version is inside the 6
# free ones.

variable "build_region" {
  description = "Region of the Artifact Registry repo and the Cloud Build connection/triggers. Must match infra's build_region."
  type        = string
  default     = "us-central1"
}

variable "images_keep_count" {
  description = "Versions kept per image in Artifact Registry; older ones are deleted by the cleanup policy. 3 x ~150 MB stays under the 0.5 GB free storage for one image; lower it if you build several images."
  type        = number
  default     = 3

  validation {
    condition     = var.images_keep_count >= 1 && var.images_keep_count <= 10
    error_message = "Keep between 1 and 10 versions per image."
  }
}

locals {
  build_farm_apis = [
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "secretmanager.googleapis.com",
  ]
  # Created by Google when the Cloud Build API is enabled. It reads the
  # GitHub token for the 2nd-gen connection.
  cloudbuild_service_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

resource "google_project_service" "build_farm" {
  for_each = toset(local.build_farm_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- Artifact Registry ------------------------------------------------------

# Google-managed encryption (customer-managed keys cost money).
resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.build_region
  repository_id = "images"
  description   = "amd64 images built by Cloud Build; the Oracle cluster copies them into Zot"
  format        = "DOCKER"

  # Cleanup runs about once a day. A version matching a Delete rule AND the
  # Keep rule is kept, so each image keeps its newest images_keep_count
  # versions and loses everything older (tagged or not).
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state = "UNTAGGED"
    }
  }

  cleanup_policies {
    id     = "delete-older-than-a-day"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "86400s"
    }
  }

  cleanup_policies {
    id     = "keep-newest"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.images_keep_count
    }
  }

  # Container Scanning is billed per image; leave it off.
  vulnerability_scanning_config {
    enablement_config = "DISABLED"
  }

  depends_on = [google_project_service.build_farm]
}

# --- Build identity ---------------------------------------------------------

resource "google_service_account" "cloud_build" {
  project      = var.project_id
  account_id   = "cloud-build-amd64"
  display_name = "Cloud Build amd64 builds (push to images, write logs)"
}

# Builds that run as a user-managed service account must log to Cloud
# Logging (cloudbuild/amd64.yaml sets CLOUD_LOGGING_ONLY).
resource "google_project_iam_member" "cloud_build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.cloud_build.member
}

resource "google_artifact_registry_repository_iam_member" "cloud_build_push" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.cloud_build.member
}

# --- Cluster pull identity --------------------------------------------------

# Read-only on "images" and nothing else. Its JSON key (gcloud, by hand) goes
# into the cluster's SOPS secret multiarch/multiarch-creds.
resource "google_service_account" "ar_pull" {
  project      = var.project_id
  account_id   = "ar-pull-cluster"
  display_name = "Oracle cluster: read-only pulls from images"
}

resource "google_artifact_registry_repository_iam_member" "ar_pull_read" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.ar_pull.member
}

# --- GitHub token for the 2nd-gen connection -------------------------------

# Empty on purpose: add the token with
#   gcloud secrets versions add cloudbuild-github-token --data-file=-
resource "google_secret_manager_secret" "github_token" {
  project   = var.project_id
  secret_id = "cloudbuild-github-token"

  replication {
    auto {}
  }

  depends_on = [google_project_service.build_farm]
}

resource "google_secret_manager_secret_iam_member" "github_token_cloudbuild" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.github_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.cloudbuild_service_agent

  depends_on = [google_project_service.build_farm]
}

# --- What CI needs for infra/cloudbuild.tf ----------------------------------

# Plan reads connections, linked repos and triggers (triggers are covered by
# the cloudbuild.builds.* permissions).
resource "google_project_iam_member" "plan_cloudbuild" {
  for_each = toset(["roles/cloudbuild.connectionViewer", "roles/cloudbuild.builds.viewer"])

  project = var.project_id
  role    = each.value
  member  = google_service_account.plan.member
}

# Apply creates the connection, links repos and creates triggers. It cannot
# touch the secret, the registry or IAM.
resource "google_project_iam_member" "apply_cloudbuild" {
  for_each = toset(["roles/cloudbuild.connectionAdmin", "roles/cloudbuild.builds.editor"])

  project = var.project_id
  role    = each.value
  member  = google_service_account.apply.member
}

# A trigger that runs as cloud-build-amd64 needs actAs on it, nothing more.
resource "google_service_account_iam_member" "apply_can_attach_build_sa" {
  service_account_id = google_service_account.cloud_build.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.apply.member
}

output "build_sa_email" {
  value = google_service_account.cloud_build.email
}

output "ar_pull_sa_email" {
  value = google_service_account.ar_pull.email
}

output "images_registry" {
  description = "Prefix of every image: <this>/<name>:<tag>. Also the cluster's GCP_AR_REPO."
  value       = "${var.build_region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "github_token_secret" {
  value = google_secret_manager_secret.github_token.id
}
