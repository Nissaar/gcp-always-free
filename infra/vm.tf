# Every setting that decides whether this VM is free is fixed here on
# purpose (machine type, disk type, network tier) rather than exposed as a
# variable.

#trivy:ignore:GCP-0033 Customer-managed encryption keys cost money; Google-managed encryption is used.
resource "google_compute_instance" "vm" {
  name                      = var.vm_name
  zone                      = var.zone
  machine_type              = "e2-micro"
  tags                      = ["iap-ssh", "tailscale"]
  allow_stopping_for_update = true
  deletion_protection       = var.deletion_protection

  labels = {
    tier = "always-free"
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image = var.image
      size  = var.disk_size_gb
      # pd-balanced is the default and is NOT in the free tier.
      type = "pd-standard"
    }
  }

  # IPv6-only on the internet. No access_config block = no external IPv4 (that one costs about
  # USD 3.65/month). The internal IPv4 stays for IAP SSH and Google APIs.
  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    stack_type = "IPV4_IPV6"

    ipv6_access_config {
      # Premium tier: free egress is 1 GB/month (README "Egress budget"). Standard tier would give
      # 200 GiB but is only in Preview for IPv6.
      network_tier = "PREMIUM"
    }
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
    # Google VM Manager (OS Config) agent: installs the weekly patch deployment in patch-deployment.tf. Free for up to 100 VMs per billing account.
    enable-osconfig = var.patch_installer == "osconfig" ? "TRUE" : "FALSE"
    # Docker + the kuma stack from stacks/kuma/ (files listed by name, never a glob: a local .env
    # must never end up in metadata/state). Secrets go into /opt/stacks/kuma/.env on the VM by hand.
    startup-script = templatefile("${path.module}/startup.sh.tftpl", {
      stack_files = {
        for f in ["docker-compose.yml", ".env.example", "serve.json", "sync.sh", "push.sh", "up.sh"] :
        f => filebase64("${path.module}/../stacks/kuma/${f}")
      }
      # OS patching (patch/README.md): the agent and its installer, listed by name. Settings below; secrets only in /etc/patch-agent.env on the VM.
      patch_files = {
        for f in ["patch-agent", "apply-patching.sh"] :
        f => filebase64("${path.module}/../patch/${f}")
      }
      vm_name           = var.vm_name
      patch_reboot_mode = var.patch_reboot_mode
      patch_installer   = var.patch_installer
    })
  }

  service_account {
    email  = var.vm_service_account_email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    provisioning_model  = "STANDARD"
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  lifecycle {
    # A newer image in the family must not force a rebuild.
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }
}
