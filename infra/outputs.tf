output "vm_name" {
  value = google_compute_instance.vm.name
}

output "zone" {
  value = google_compute_instance.vm.zone
}

output "external_ipv6" {
  description = "The VM's only internet address (no IPv4)."
  value       = try(google_compute_instance.vm.network_interface[0].ipv6_access_config[0].external_ipv6, null)
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.vm.name} --zone ${google_compute_instance.vm.zone} --project ${var.project_id} --tunnel-through-iap"
}
