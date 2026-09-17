# Safe to commit: RFC 1918 only, no secrets.
#
# cp-N lives on pve-N so a host failure costs one control plane, never two.
# Workers 1 and 2 sit on the Ultra 7 (most RAM).
# ops-1 goes on pve-1's "local" (the second physical NVMe) to keep its I/O
# off the ZFS pool already carrying seven VM disks.

nodes = {
  "k8s-cp-1"   = { host = "pve-1", store = "nvme-zfs", vmid = 101, cores = 4, memory = 8192, disk = 60, ip = "192.168.1.221", role = "server" }
  "k8s-cp-2"   = { host = "pve-2", store = "local", vmid = 102, cores = 4, memory = 8192, disk = 60, ip = "192.168.1.222", role = "server" }
  "k8s-cp-3"   = { host = "pve-3", store = "local", vmid = 103, cores = 4, memory = 8192, disk = 60, ip = "192.168.1.223", role = "server" }
  "k8s-work-1" = { host = "pve-1", store = "nvme-zfs", vmid = 111, cores = 8, memory = 24576, disk = 120, ip = "192.168.1.224", role = "agent" }
  "k8s-work-2" = { host = "pve-1", store = "nvme-zfs", vmid = 112, cores = 8, memory = 16384, disk = 120, ip = "192.168.1.225", role = "agent" }
  "k8s-work-3" = { host = "pve-2", store = "local", vmid = 113, cores = 6, memory = 16384, disk = 120, ip = "192.168.1.226", role = "agent" }
  "k8s-work-4" = { host = "pve-3", store = "local", vmid = 114, cores = 6, memory = 16384, disk = 120, ip = "192.168.1.227", role = "agent" }
  "ops-1"      = { host = "pve-1", store = "local", vmid = 121, cores = 4, memory = 4096, disk = 150, ip = "192.168.1.220", role = "ops" }
}
