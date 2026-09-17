output "node_addresses" {
  description = "Planned static address per VM."
  value       = { for k, v in var.nodes : k => v.ip }
}

output "control_planes" {
  value = [for k, v in var.nodes : k if v.role == "server"]
}

output "workers" {
  value = [for k, v in var.nodes : k if v.role == "agent"]
}

# Phase 6 builds its Ansible inventory from this rather than maintaining the
# same eight addresses in two places.
output "ansible_inventory" {
  value = {
    rke2_servers = { for k, v in var.nodes : k => { ansible_host = v.ip } if v.role == "server" }
    rke2_agents  = { for k, v in var.nodes : k => { ansible_host = v.ip } if v.role == "agent" }
    ops          = { for k, v in var.nodes : k => { ansible_host = v.ip } if v.role == "ops" }
  }
}
