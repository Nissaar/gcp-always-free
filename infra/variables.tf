variable "project_id" {
  description = "GCP project ID. CI: repository variable GCP_PROJECT_ID. Required."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id is the project ID: 6 to 30 lower-case letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Only us-east1, us-central1 and us-west1 have the free e2-micro. CI: optional repository variable GCP_REGION; keep it equal to bootstrap's region."
  type        = string
  default     = "us-east1"

  validation {
    condition     = contains(["us-east1", "us-central1", "us-west1"], var.region)
    error_message = "The e2-micro is only free in us-east1, us-central1 and us-west1."
  }
}

variable "zone" {
  description = "Zone inside var.region. CI: optional repository variable GCP_ZONE."
  type        = string
  default     = "us-east1-b"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone)) && startswith(var.zone, "${var.region}-")
    error_message = "zone must be inside region (for example us-east1-b for us-east1)."
  }
}

variable "vm_name" {
  description = "Instance name."
  type        = string
  default     = "free-vm"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.vm_name))
    error_message = "vm_name is a valid instance name: lower-case letters, digits and hyphens, starting with a letter."
  }
}

variable "vm_service_account_email" {
  description = "Runtime service account created by bootstrap/ (output VM_SA_EMAIL; CI: repository variable VM_SA_EMAIL). Required."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\\.iam\\.gserviceaccount\\.com$", var.vm_service_account_email))
    error_message = "vm_service_account_email looks like vm-free-tier@<project-id>.iam.gserviceaccount.com (bootstrap/ output VM_SA_EMAIL)."
  }
}

variable "enable_tailscale_direct_ipv6" {
  description = "Open inbound UDP 41641 over IPv6 (Tailscale's WireGuard port) on VMs tagged tailscale. Without it every tailnet packet goes through a DERP relay: slower, still works. Set false if you do not use Tailscale."
  type        = bool
  default     = true
}

variable "image" {
  description = "Boot image. Only read at creation; changing it later does not rebuild the VM."
  type        = string
  default     = "debian-cloud/debian-13"
}

variable "disk_size_gb" {
  description = "Boot disk size. The free tier covers 30 GB of standard persistent disk in total."
  type        = number
  default     = 30

  validation {
    condition     = var.disk_size_gb >= 10 && var.disk_size_gb <= 30
    error_message = "Keep the disk between 10 and 30 GB to stay in the free tier."
  }
}

variable "deletion_protection" {
  description = "Block deletion of the VM. Set to false before a planned destroy."
  type        = bool
  default     = true
}

variable "patch_reboot_mode" {
  description = "What the VM does about a reboot that an update needs: alert (default: reminder by ntfy every 7 days, you reboot with ChatOps `reboot free-vm`), staggered (reboots by itself when needed on Wednesdays at 00:00 UTC = 04:00 local time) or none. patch/README.md."
  type        = string
  default     = "alert"

  validation {
    condition     = contains(["alert", "staggered", "none"], var.patch_reboot_mode)
    error_message = "patch_reboot_mode must be alert, staggered or none."
  }
}

variable "patch_installer" {
  description = "Who installs the updates: osconfig (default: Google VM Manager, the weekly patch deployment in patch-deployment.tf, free for up to 100 VMs per billing account) or unattended (apt's unattended-upgrades on the VM, no Google API). patch/README.md."
  type        = string
  default     = "osconfig"

  validation {
    condition     = contains(["osconfig", "unattended"], var.patch_installer)
    error_message = "patch_installer must be osconfig or unattended."
  }
}
