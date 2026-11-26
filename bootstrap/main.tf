# One-time, run locally with your own credentials (scripts/bootstrap.sh).
# Creates what CI needs before it can run: APIs, the state bucket, keyless
# GitHub -> GCP auth (Workload Identity Federation), the CI service accounts,
# the VM's runtime service account and the budget alerts.

locals {
  apis = [
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "osconfig.googleapis.com",
    "oslogin.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- OpenTofu state -------------------------------------------------------

#trivy:ignore:GCP-0066 Customer-managed encryption keys cost money; Google-managed encryption is enough for this state.
#trivy:ignore:GCP-0077 Access logs need a second bucket and grow forever; the state is only touched by CI and its own versioning keeps history.
resource "google_storage_bucket" "tfstate" {
  project                     = var.project_id
  name                        = "${var.project_id}-tfstate"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Keep the last 10 state versions; older ones would slowly eat the 5 GB free tier.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

# --- GitHub Actions -> GCP (no JSON keys) ----------------------------------

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"
  description                        = "GitHub Actions in ${var.github_repository}"

  attribute_mapping = {
    "google.subject"           = "assertion.sub"
    "attribute.repository"     = "assertion.repository"
    "attribute.repository_id"  = "assertion.repository_id"
    "attribute.ref"            = "assertion.ref"
    "attribute.event_name"     = "assertion.event_name"
    "attribute.repo_ref_event" = "assertion.repository_id + '@' + assertion.ref + '@' + assertion.event_name"
  }

  # Tokens from any other repository are rejected outright.
  attribute_condition = "assertion.repository_id == '${var.github_repository_id}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Plan identity: read-only on compute, read/write on state (for locks).
# Any branch or PR in the repo can use it.
resource "google_service_account" "plan" {
  project      = var.project_id
  account_id   = "tf-plan"
  display_name = "OpenTofu plan (GitHub Actions)"
}

resource "google_project_iam_member" "plan_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = google_service_account.plan.member
}

# VM Manager patch deployment (infra/patch-deployment.tf): the plan identity reads it, the apply identity manages it.
resource "google_project_iam_member" "plan_patch_viewer" {
  project = var.project_id
  role    = "roles/osconfig.patchDeploymentViewer"
  member  = google_service_account.plan.member
}

resource "google_service_account_iam_member" "plan_wif" {
  service_account_id = google_service_account.plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/${var.github_repository_id}"
}

# Apply identity: can change compute resources. Only a manual
# workflow_dispatch run on main can use it, so a PR or a feature branch
# can never apply.
resource "google_service_account" "apply" {
  project      = var.project_id
  account_id   = "tf-apply"
  display_name = "OpenTofu apply (GitHub Actions, manual on main)"
}

resource "google_project_iam_member" "apply_compute_admin" {
  project = var.project_id
  role    = "roles/compute.admin"
  member  = google_service_account.apply.member
}

resource "google_project_iam_member" "apply_patch_admin" {
  project = var.project_id
  role    = "roles/osconfig.patchDeploymentAdmin"
  member  = google_service_account.apply.member
}

resource "google_service_account_iam_member" "apply_wif" {
  service_account_id = google_service_account.apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repo_ref_event/${var.github_repository_id}@refs/heads/main@workflow_dispatch"
}

resource "google_storage_bucket_iam_member" "state_access" {
  for_each = {
    plan  = google_service_account.plan.member
    apply = google_service_account.apply.member
  }

  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectUser"
  member = each.value
}

# --- VM runtime identity ---------------------------------------------------

# Dedicated service account with no project roles, so the VM does not run
# as the default compute account (which has Editor on the project).
resource "google_service_account" "vm" {
  project      = var.project_id
  account_id   = "vm-free-tier"
  display_name = "Always-free VM runtime"
}

resource "google_service_account_iam_member" "apply_can_attach_vm_sa" {
  service_account_id = google_service_account.vm.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.apply.member
}

# --- Budget alerts (emails go to billing account admins) -------------------

# Cost after free-tier usage but before trial credits: anything above 0 here
# is what you would really pay once the trial ends.
resource "google_billing_budget" "free_tier_guard" {
  billing_account = var.billing_account_id
  display_name    = "${var.project_id} - beyond free tier"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    credit_types_treatment = "INCLUDE_SPECIFIED_CREDITS"
    credit_types           = ["FREE_TIER"]
  }

  amount {
    specified_amount {
      units = tostring(var.guard_budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.1
  }
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  # Also feeds the kill switch (killswitch.tf) when it is on; emails still go out.
  dynamic "all_updates_rule" {
    for_each = var.enable_billing_kill_switch ? [1] : []
    content {
      pubsub_topic   = google_pubsub_topic.budget[0].id
      schema_version = "1.0"
    }
  }

  depends_on = [google_project_service.apis]
}

# Gross spend across every project on the billing account, so you can see
# how fast the trial credit is being used.
resource "google_billing_budget" "trial_burn" {
  billing_account = var.billing_account_id
  display_name    = "Free trial credit burn"

  budget_filter {
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
    calendar_period        = "YEAR"
  }

  amount {
    specified_amount {
      units = tostring(var.trial_budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.25, 0.5, 0.75, 0.9]
    content {
      threshold_percent = threshold_rules.value
    }
  }

  depends_on = [google_project_service.apis]
}
