# Build farm settings (docs/BUILD-FARM.md, docs/WHAT-YOU-DO.md). Edit the
# defaults here, open a PR, read the plan, merge, run the apply. They are
# not secret, so they live in git (the repo's .gitignore drops *.tfvars).

variable "build_region" {
  description = "Region of the Cloud Build connection, triggers and builds. Must match bootstrap's build_region (where the images repo is)."
  type        = string
  default     = "us-central1"
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repos in build_repos. Required once github_app_installation_id is not 0; empty while the build farm is off."
  type        = string
  default     = ""

  validation {
    condition     = var.github_owner == "" || can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", var.github_owner))
    error_message = "github_owner is a GitHub login (letters, digits, hyphens), not owner/name."
  }
}

variable "github_app_installation_id" {
  description = "Installation ID of the Google Cloud Build GitHub App (the number at the end of https://github.com/settings/installations/<id>). 0 = build farm off: no connection, no triggers."
  type        = number
  default     = 0

  validation {
    condition     = var.github_app_installation_id == 0 || var.github_owner != ""
    error_message = "Set github_owner (your GitHub login) before you turn the build farm on with github_app_installation_id."
  }
}

variable "github_token_secret_version" {
  description = "Version number of the secret cloudbuild-github-token that holds the GitHub token. 1 after the first gcloud secrets versions add; bump it when you replace the token."
  type        = number
  default     = 1
}

variable "build_repos" {
  description = "GitHub repos (name under github_owner) that Cloud Build turns into linux/amd64 images on every push to main and every tag. image defaults to the repo name; dockerfile and context are paths from the repo root."
  type = map(object({
    image      = optional(string)
    dockerfile = optional(string, "Dockerfile")
    context    = optional(string, ".")
  }))
  default = {
    # "photo-sweep" = {}
    # "my-api"      = { image = "api", dockerfile = "docker/Dockerfile", context = "." }
  }

  validation {
    condition     = alltrue([for name, r in var.build_repos : can(regex("^[A-Za-z0-9._-]+$", name))])
    error_message = "Keys are plain repo names (no owner/ prefix)."
  }
}
