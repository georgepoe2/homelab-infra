# One resource, eight machines. Adding a ninth worker is four lines of data
# in nodes.auto.tfvars, not a copied resource block.

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  node_name   = each.value.host
  vm_id       = each.value.vmid
  name        = each.key
  description = "Managed by OpenTofu. Role: ${each.value.role}."
  tags        = sort(["opentofu", "rookery", each.value.role])

  on_boot = true

  # Template 9002 is UEFI on q35 with a VirtIO SCSI single controller.
  # The provider defaults bios to "seabios" and scsi_hardware to
  # "virtio-scsi-pci", and applies those defaults to the clone — so both must
  # be stated. seabios will not boot a UEFI install at all, and Proxmox only
  # honours iothread on the "single" controller.
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  # No efi_disk block: the full clone carries the template's EFI disk across.
  # Declaring one here risks the provider trying to create a second.

  #  clone {
  #    vm_id = var.template_vmid
  #    full  = true # linked clones chain every VM to the template forever
  #  }

  clone {
    vm_id     = var.template_vmid
    node_name = var.template_node # "pve-1" — confirmed, 9002 lives there
    full      = true
    retries   = 3
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = each.value.memory

    # Ballooning OFF on control planes: etcd is latency-sensitive and reclaimed
    # memory under pressure is how you get spurious leader elections.
    # floating == dedicated means "ballooning allowed"; 0 disables it.
    floating = each.value.role == "server" ? 0 : each.value.memory
  }

  disk {
    datastore_id = each.value.store
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
    ssd          = true
    iothread     = true

    # A zfspool datastore accepts only raw; a dir datastore takes qcow2,
    # which is thin-provisioned and snapshottable. Derived, not hardcoded.
    file_format = each.value.store == "nvme-zfs" ? "raw" : "qcow2"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = each.value.store

    # Set DNS explicitly. Leaving it empty makes Proxmox fall back to the host
    # node's resolver config — which works, but hides a dependency outside the
    # code. See Phase 2: lab machines resolve against .250 directly.
    dns {
      servers = var.dns_servers
      domain  = var.search_domain
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      username = var.vm_user
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    # prevent_destroy CANNOT be an expression — it must be a literal, so it
    # cannot be scoped to control planes only from inside a for_each. All eight
    # are protected while you learn; Phase 8 removes this deliberately as the
    # first step of the destroy-and-rebuild drill.
    prevent_destroy = true

    # Populate from what `tofu plan` reports as drift on a second run.
    # Leave empty until you have actually seen the drift — guessing here
    # silently ignores changes you wanted to apply.
    ignore_changes = [clone]
  }
}
