# Build farm, part 2 of 2 (docs/BUILD-FARM.md): the Cloud Build 2nd-gen
# GitHub connection, one linked repo per entry of build_repos and two
# triggers per repo (push to main, any tag). Every trigger runs
# cloudbuild/amd64.yaml inline as the service account cloud-build-amd64.
#
# Part 1 (registry, service accounts, the token secret, the roles CI needs
# for this file) is bootstrap/cloudbuild.tf, applied with your own account.
# Nothing here exists while github_app_installation_id is 0.

locals {
  build_farm = var.github_app_installation_id != 0

  build_sa_email = "cloud-build-amd64@${var.project_id}.iam.gserviceaccount.com"
  images_repo    = "${var.build_region}-docker.pkg.dev/${var.project_id}/images"

  # The shared build, read once. infra/ is the OpenTofu root; the file sits
  # at the repo root so it can also be used with gcloud builds submit.
  amd64_build = yamldecode(file("${path.module}/../cloudbuild/amd64.yaml"))

  repos = local.build_farm ? {
    for name, r in var.build_repos : name => {
      id         = replace(lower(name), "/[^a-z0-9-]/", "-")
      image      = coalesce(r.image, lower(name))
      dockerfile = r.dockerfile
      context    = r.context
    }
  } : {}

  # One trigger per repo and event: Cloud Build allows either a branch or a
  # tag filter in one push trigger, not both.
  triggers = merge([
    for name, r in local.repos : {
      "${name}/main" = { repo = name, event = "main", branch = "^main$", tag = null }
      "${name}/tag"  = { repo = name, event = "tag", branch = null, tag = ".*" }
    }
  ]...)
}

resource "google_cloudbuildv2_connection" "github" {
  count = local.build_farm ? 1 : 0

  project  = var.project_id
  location = var.build_region
  name     = "github"

  github_config {
    app_installation_id = var.github_app_installation_id
    authorizer_credential {
      # A classic GitHub token (scopes repo, read:user) that you added to
      # this secret with gcloud; Cloud Build does not accept fine-grained ones.
      oauth_token_secret_version = "projects/${var.project_id}/secrets/cloudbuild-github-token/versions/${var.github_token_secret_version}"
    }
  }
}

resource "google_cloudbuildv2_repository" "build" {
  for_each = local.repos

  project           = var.project_id
  location          = var.build_region
  name              = each.value.id
  parent_connection = google_cloudbuildv2_connection.github[0].name
  remote_uri        = "https://github.com/${var.github_owner}/${each.key}.git"
}

resource "google_cloudbuild_trigger" "amd64" {
  for_each = local.triggers

  project         = var.project_id
  location        = var.build_region
  name            = "amd64-${local.repos[each.value.repo].id}-${each.value.event}"
  description     = "linux/amd64 image of ${var.github_owner}/${each.value.repo} on ${each.value.event == "main" ? "push to main" : "every tag"} (cloudbuild/amd64.yaml)"
  service_account = "projects/${var.project_id}/serviceAccounts/${local.build_sa_email}"

  repository_event_config {
    repository = google_cloudbuildv2_repository.build[each.value.repo].id
    push {
      branch = each.value.branch
      tag    = each.value.tag
    }
  }

  substitutions = {
    _AR_REPO    = local.images_repo
    _IMAGE      = local.repos[each.value.repo].image
    _DOCKERFILE = local.repos[each.value.repo].dockerfile
    _CONTEXT    = local.repos[each.value.repo].context
    _SOURCE_URL = "https://github.com/${var.github_owner}/${each.value.repo}"
  }

  build {
    timeout       = local.amd64_build.timeout
    substitutions = local.amd64_build.substitutions

    dynamic "step" {
      for_each = local.amd64_build.steps
      content {
        id         = try(step.value.id, null)
        name       = step.value.name
        entrypoint = try(step.value.entrypoint, null)
        args       = try(step.value.args, null)
        env        = try(step.value.env, null)
        wait_for   = try(step.value.waitFor, null)
      }
    }

    options {
      logging             = local.amd64_build.options.logging
      substitution_option = local.amd64_build.options.substitutionOption
    }
  }
}

output "images_registry" {
  description = "Where the amd64 images land: <this>/<image>:<sha|latest|tag>."
  value       = local.images_repo
}

output "build_triggers" {
  description = "Cloud Build triggers made from build_repos."
  value       = sort([for t in google_cloudbuild_trigger.amd64 : t.name])
}
