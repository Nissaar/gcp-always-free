# scripts/bootstrap.sh writes the bucket name (output TF_STATE_BUCKET).
terraform {
  backend "gcs" {
    bucket = "<your-project-id>-tfstate"
    prefix = "infra"
  }
}
