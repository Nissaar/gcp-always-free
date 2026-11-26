# Hard spending cap (optional): when this project's spend beyond the free tier
# passes guard_budget_amount, a Cloud Run function detaches billing from the
# project, which stops its paid resources. Google's documented pattern.
#
# On by default since the VM is IPv6-only (a public IPv4, ~USD 3.65/month,
# would trip it within a week). Live from the first run (kill_switch_dry_run
# defaults to false, decided 2026-11-07): billing really is detached. To only
# log instead, set the default to true in variables.tf and re-run the
# bootstrap. Defaults, not tfvars: scripts/bootstrap.sh rewrites
# terraform.tfvars on every run.

locals {
  kill_switch = var.enable_billing_kill_switch ? 1 : 0
  kill_switch_apis = [
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
  ]
}

resource "google_project_service" "kill_switch" {
  for_each = var.enable_billing_kill_switch ? toset(local.kill_switch_apis) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_pubsub_topic" "budget" {
  count   = local.kill_switch
  project = var.project_id
  name    = "budget-free-tier-guard"

  depends_on = [google_project_service.kill_switch]
}

resource "google_service_account" "kill_switch" {
  count        = local.kill_switch
  project      = var.project_id
  account_id   = "billing-kill-switch"
  display_name = "Detaches billing when the free-tier guard budget is exceeded"
}

# Project Billing Manager on this project only: enough to unlink billing,
# nothing on the billing account itself.
resource "google_project_iam_member" "kill_switch_billing" {
  count   = local.kill_switch
  project = var.project_id
  role    = "roles/billing.projectManager"
  member  = "serviceAccount:${google_service_account.kill_switch[0].email}"
}

# The function is built by Cloud Build. Since 2024 new projects no longer give the default compute service account
# the rights to do that (the first apply failed at "gcs-fetcher" with exit status 3 while fetching the source), so the
# build runs as its own account with the role Google documents for it.
resource "google_service_account" "kill_switch_build" {
  count        = local.kill_switch
  project      = var.project_id
  account_id   = "kill-switch-build"
  display_name = "Builds the billing kill switch function"
}

resource "google_project_iam_member" "kill_switch_build" {
  count   = local.kill_switch
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${google_service_account.kill_switch_build[0].email}"
}

data "archive_file" "kill_switch" {
  count       = local.kill_switch
  type        = "zip"
  source_dir  = "${path.module}/killswitch"
  excludes    = ["test_main.py", "__pycache__"]
  output_path = "${path.module}/.killswitch.zip"
}

resource "google_storage_bucket_object" "kill_switch" {
  count  = local.kill_switch
  bucket = google_storage_bucket.tfstate.name
  name   = "functions/killswitch-${data.archive_file.kill_switch[0].output_md5}.zip"
  source = data.archive_file.kill_switch[0].output_path
}

resource "google_cloudfunctions2_function" "kill_switch" {
  count    = local.kill_switch
  project  = var.project_id
  location = var.region
  name     = "billing-kill-switch"

  depends_on = [google_project_iam_member.kill_switch_build]

  build_config {
    runtime         = "python312"
    entry_point     = "stop_billing"
    service_account = "projects/${var.project_id}/serviceAccounts/${google_service_account.kill_switch_build[0].email}"
    source {
      storage_source {
        bucket = google_storage_bucket.tfstate.name
        object = google_storage_bucket_object.kill_switch[0].name
      }
    }
  }

  service_config {
    max_instance_count    = 1
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = google_service_account.kill_switch[0].email
    environment_variables = {
      PROJECT_ID = var.project_id
      DRY_RUN    = tostring(var.kill_switch_dry_run)
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.budget[0].id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.kill_switch[0].email
  }
}

# Eventarc delivers Pub/Sub messages by invoking the function's Run service.
resource "google_cloud_run_service_iam_member" "kill_switch_invoker" {
  count    = local.kill_switch
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.kill_switch[0].service_config[0].service
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.kill_switch[0].email}"
}
