# These become GitHub Actions repository variables (scripts/bootstrap.sh sets them).

output "GCP_PROJECT_ID" {
  value = var.project_id
}

output "TF_STATE_BUCKET" {
  value = google_storage_bucket.tfstate.name
}

output "WIF_PROVIDER" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "PLAN_SA" {
  value = google_service_account.plan.email
}

output "APPLY_SA" {
  value = google_service_account.apply.email
}

output "VM_SA_EMAIL" {
  value = google_service_account.vm.email
}
