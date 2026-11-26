variable "project_id" {
  description = "GCP project that holds the always-free VM and the OpenTofu state. Required (the project must exist and have billing linked)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id is the project ID (not the name or the number): 6 to 30 lower-case letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Region for the state bucket. Must be a Cloud Storage free-tier region."
  type        = string
  default     = "us-east1"

  validation {
    condition     = contains(["us-east1", "us-central1", "us-west1"], var.region)
    error_message = "Free tier only covers us-east1, us-central1 and us-west1."
  }
}

variable "billing_account_id" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX), used for the budget alerts. Required."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id)) && var.billing_account_id != "000000-000000-000000"
    error_message = "billing_account_id looks like 0A1B2C-3D4E5F-6A7B8C (console: Billing -> Account management), not the placeholder."
  }
}

variable "github_repository" {
  description = "owner/name of YOUR private GitHub copy of this repository: the only repository allowed to deploy. Required: no default on purpose."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$", var.github_repository))
    error_message = "github_repository must look like owner/name (your account and your PRIVATE copy), not a placeholder."
  }
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID (gh api repos/<owner>/<name> --jq .id; scripts/bootstrap.sh reads it). Trusting the ID, not the name, stops a deleted-and-recreated repo with the same name from inheriting access. Required."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]{3,14}$", var.github_repository_id)) && var.github_repository_id != "123456789"
    error_message = "github_repository_id is the numeric id of your repository (gh api repos/<owner>/<name> --jq .id), not the example."
  }
}

variable "guard_budget_amount" {
  description = "Monthly alert threshold, in the billing account currency, for spend in this project that the free tier does NOT cover. The kill switch trips when it is passed."
  type        = number
  default     = 1

  validation {
    condition     = var.guard_budget_amount >= 1 && var.guard_budget_amount <= 100 && floor(var.guard_budget_amount) == var.guard_budget_amount
    error_message = "guard_budget_amount is a whole number between 1 and 100: it is a safety threshold, keep it low."
  }
}

variable "trial_budget_amount" {
  description = "Free trial credit amount, in the billing account currency. Alerts as the trial credit is consumed across the whole billing account."
  type        = number
  default     = 300

  validation {
    condition     = var.trial_budget_amount >= 1 && floor(var.trial_budget_amount) == var.trial_budget_amount
    error_message = "trial_budget_amount is a whole number of at least 1."
  }
}

variable "enable_billing_kill_switch" {
  description = "Detach billing from the project when spend beyond the free tier passes guard_budget_amount. Read bootstrap/killswitch.tf first."
  type        = bool
  default     = true
}

variable "kill_switch_dry_run" {
  description = "Log what the kill switch would do instead of doing it. False = live: billing is really detached when spend passes the budget. Set to true here (and re-run the bootstrap) to try it without effect."
  type        = bool
  default     = false
}
