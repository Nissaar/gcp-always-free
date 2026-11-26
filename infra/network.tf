resource "google_compute_network" "main" {
  name                    = "free-tier-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Dual-stack: the internal IPv4 range stays (IAP SSH and Google APIs use it); the external IPv6
# range gives the VM its only internet address. External IPv6 addresses cost nothing.
#trivy:ignore:GCP-0029 VPC flow logs are billed as log volume; not worth it for one VM.
#trivy:ignore:GCP-0076 Same as above (subnet logging check).
resource "google_compute_subnetwork" "main" {
  name                     = "free-tier-${var.region}"
  region                   = var.region
  network                  = google_compute_network.main.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true
  stack_type               = "IPV4_IPV6"
  ipv6_access_type         = "EXTERNAL"
}

# SSH is only reachable through Identity-Aware Proxy (gcloud compute ssh
# --tunnel-through-iap), never from the internet. Everything else inbound
# hits the VPC's implicit deny.
resource "google_compute_firewall" "iap_ssh" {
  name          = "allow-ssh-from-iap"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["iap-ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Tailscale direct connections over IPv6 (WireGuard, UDP 41641, published by the kuma stack's
# tailscale container). Without it every tailnet packet goes through a DERP relay; it works,
# just slower. WireGuard drops anything that is not signed by a known peer.
#trivy:ignore:GCP-0073 Tailscale's WireGuard port has to accept peers from anywhere (only UDP 41641, one tagged VM).
resource "google_compute_firewall" "tailscale_ipv6" {
  count = var.enable_tailscale_direct_ipv6 ? 1 : 0

  name          = "allow-tailscale-ipv6"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = ["::/0"]
  target_tags   = ["tailscale"]

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }
}
