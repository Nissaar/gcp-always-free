# Google VM Manager (OS Config) installs the updates on the VM: free for up to 100 VMs per billing account
# (https://cloud.google.com/compute/vm-manager/pricing). Needs osconfig.googleapis.com and the roles in bootstrap/main.tf (run scripts/bootstrap.sh once).
# It installs but never reboots (reboot_config NEVER): the reboot is patch-agent's job (alert mode: you, with ChatOps `reboot free-vm`).
# Tuesday 22:00 UTC, two hours before the Wednesday 00:00 UTC (04:00 local time) reboot night of staggered mode.
# apt UPGRADE = every upgradable package (unattended-upgrades alone would take only security origins); packages are never removed.
resource "google_os_config_patch_deployment" "weekly" {
  count = var.patch_installer == "osconfig" ? 1 : 0

  project             = var.project_id
  patch_deployment_id = "weekly-apt"
  description         = "Weekly apt upgrade of ${var.vm_name}; no reboot (patch-agent handles it). Managed by OpenTofu."

  instance_filter {
    instances = ["zones/${var.zone}/instances/${google_compute_instance.vm.name}"]
  }

  patch_config {
    reboot_config = "NEVER"
    apt {
      type = "UPGRADE"
    }
  }

  recurring_schedule {
    time_zone {
      id = "UTC"
    }
    time_of_day {
      hours   = 22
      minutes = 0
      seconds = 0
      nanos   = 0
    }
    weekly {
      day_of_week = "TUESDAY"
    }
  }

  rollout {
    mode = "ZONE_BY_ZONE"
    disruption_budget {
      fixed = 1
    }
  }

  duration = "3600s"
}
