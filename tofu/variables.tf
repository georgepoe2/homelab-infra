variable "nodes" {
  description = "The eight VMs, keyed by hostname."
  type = map(object({
    host   = string # Proxmox node it lives on
    store  = string # datastore on that node
    vmid   = number
    cores  = number
    memory = number # MiB
    disk   = number # GiB
    ip     = string
    role   = string # server | agent | ops
  }))
}

variable "template_vmid" {
  description = "Golden image template from Phase 3 (rocky9-base-20260914, on pve-nfs)."
  type        = number
  default     = 9002
}

variable "template_node" {
  description = "Proxmox node that owns template 9002's config file. Shared storage holds the disks; the .conf lives on exactly one node."
  type        = string
  default     = "pve-1"
}

variable "gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.1.250"]
}

variable "search_domain" {
  type    = string
  default = "rookery.internal"
}

variable "vm_user" {
  type    = string
  default = "rocky"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "cpu_type" {
  description = "x86-64-v3 keeps migration legal between the 8400T boxes and the Ultra 7."
  type        = string
  default     = "x86-64-v3"
}

variable "state_passphrase" {
  description = "Encrypts OpenTofu state and plan files. Supplied via TF_VAR_state_passphrase from ~/.config/homelab/env. Losing it means unreadable state — back it up like the age key."
  type        = string
  sensitive   = true
  # No default. Unset should be an error, not a weak key.
}

variable "ssh_private_key_path" {
  description = "Private key Ansible uses to reach the nodes. Written into the generated inventory."
  type        = string
  default     = "~/.ssh/id_ed25519"
}
