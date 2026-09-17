# Rookery — a homelab Kubernetes platform, built from code

Three Proxmox nodes and a Synology NAS, running a three-node HA RKE2 cluster
provisioned entirely from version control. Everything the cluster depends on
to be rebuilt lives outside the cluster, on purpose.

This repository holds the infrastructure layer: OpenTofu, Ansible, and the
decision records. The cluster's contents live in
[homelab-fleet](https://github.com/georgepoe2/homelab-fleet) and are
reconciled by Flux.

---

## Status

Built in phases. This is honest about where it is.

| Phase | State |
|---|---|
| 1 — Proxmox cluster, network, storage | ✅ Complete |
| 2 — DNS, naming, internal CA | ✅ Complete |
| 3 — Rocky 9 golden image | ✅ Complete |
| 4 — State store, repos, secrets | ✅ Complete |
| 5 — Provisioning with OpenTofu | ✅ Complete |
| 6 — RKE2 cluster | ⬜ Not started |
| 7 — Flux and the platform layer | ⬜ Not started |
| 8 — Operate: restore, rebuild, upgrade | ⬜ Not started |

---

## Architecture

```
                        Internet
                           │
                    Fios gateway (.1)
                           │
              ┌────────────┴────────────┐
              │        LAN switch       │
              └─┬────────┬────────┬─────┘
                │        │        │
   ┌────────────┴──┐  ┌──┴───┐ ┌──┴───┐   ┌──────────────┐
   │ pve-1  .215   │  │pve-2 │ │pve-3 │   │ Synology .250│
   │ Intel Ultra 7 │  │ .216 │ │ .208 │   │  AdGuard DNS │
   │ ZFS + NVMe    │  │      │ │      │   │  SeaweedFS S3│
   └───────────────┘  └──────┘ └──────┘   │  NFS exports │
              │            │        │     └──────────────┘
              └────────────┼────────┘             ▲
                           │                      │
                 8 VMs, Rocky Linux 9             │ state + snapshots
                 ├── 3× control plane  ───────────┘
                 ├── 4× worker
                 └── 1× ops
                           │
                 kube-vip VIP  .201
                 MetalLB pool  .235 → ingress-nginx
```

**Layers, and who owns what**

| Layer | Tool | Boundary |
|---|---|---|
| Hosts | Proxmox VE, manual | Below the automation line — deliberately |
| VMs | OpenTofu | Creates and destroys the eight machines |
| Node config | Ansible | Baseline that isn't in the golden image |
| Cluster | RKE2 | Installed by Ansible, configured before first boot |
| Cluster contents | Flux | Everything after `flux bootstrap` comes from Git |

---

## Design decisions

Each of these was a real fork with a real trade-off, not a default.

**RKE2 over k3s or kubeadm.** k3s is lighter but its defaults diverge from
upstream in ways that stop being helpful once you want to talk about
production Kubernetes. kubeadm is closer to the metal but leaves you
assembling the pieces. RKE2 gives conformant Kubernetes with sane defaults,
CIS hardening available, and a real upgrade story.

**OpenTofu over Terraform.** State encryption at rest, built in and enforced.
`enforced = true` means an unencrypted state write is refused rather than
silently permitted. That matters when state holds every secret the provider
touched.

**`.internal` over a purchased domain.** ICANN reserved `.internal` in 2024
for exactly this. It can never be delegated publicly, so there is no version
of this that leaks, and a DNS-over-HTTPS bypass fails cleanly instead of
quietly reaching a stranger's web server.

**The object store lives outside the cluster.** OpenTofu state and etcd
snapshots are on the NAS, not on a VM the state describes. Phase 8 destroys
all eight VMs; anything needed to rebuild them cannot be among them. This
constraint drove most of Phase 4.

**SOPS + age over Vault.** Vault is the right answer at scale and the wrong
answer for a lab: it needs to be running, unsealed and reachable before you
can decrypt the secrets that bring up the thing that would run it. SOPS
encrypts into Git, so the fleet repo is public and still safe.

**Three repos over a monorepo.** Clean permission boundaries, and Flux polls
only what concerns it. The cost is that a change spanning infrastructure and
apps is two pull requests with no atomic ordering — accepted knowingly.

**Split-horizon DNS by role, not network-wide.** See below; this one was
forced by a measurement rather than chosen up front.

---

## What broke, and what I changed

The section worth reading. Every one of these was found by measurement, not
anticipated.

### The gateway silently censors internal DNS answers

Symptom: AdGuard resolved `nas.rookery.internal` correctly when queried
directly, but the same name returned `NXDOMAIN` through the gateway — while
ad-filtering worked, proving the forwarding path was fine.

Isolating it needed two freshly-created names, one pointing at a public IP
and one at a private IP, so no cached negative could confound the result:

```
rebindtest.rookery.internal → 93.184.216.34   resolves
cachetest.rookery.internal  → 192.168.1.99    NOERROR, empty answer
```

`NOERROR` with an empty answer is the signature of a resolver that forwarded
the query, got a valid response, and **stripped the record on the way back** —
DNS rebinding protection refusing to return an RFC1918 address. The Verizon
G3100 exposes no toggle for it.

**Consequence:** no client resolving through the gateway can ever see an
internal name. Forwarding buys ad-filtering and nothing else.

**Fix:** assign resolvers by role. Lab machines point at AdGuard directly and
get internal names plus per-client query logs; household devices keep the
gateway and get filtering. This replaced a planned DHCP-server takeover
entirely — the takeover would have made a NAS load-bearing for the whole
house to solve a problem that a per-machine setting solves for free.

**Also learned:** never diagnose caching and filtering on the same name at
once. The original name carried a stale negative *and* was being filtered;
two independent faults stacked on one symptom.

### Removing the swap LV before fixing the kernel command line

Anaconda writes `rd.lvm.lv=<vg>/swap` and `resume=` onto the kernel command
line. Deleting the logical volume with those still present left the next boot
hanging in a dracut emergency shell.

Rocky 9 uses BootLoaderSpec, so those arguments live in
`/boot/loader/entries/*.conf` — editing `/etc/default/grub` and running
`grub2-mkconfig` appears to work and changes nothing. `grubby` is the tool
that updates both.

The golden image procedure now orders `grubby` **before** `lvremove`.

### Container Manager's wizard silently discarded the compose file

AdGuard's query log showed every client as `172.17.0.1`. That address belongs
to Docker's `docker0` bridge — not to the network at all.

Root cause: the container had been created through Synology Container
Manager's **Container → Create** wizard rather than as a **Project**. The
wizard never reads a compose file, so `network_mode: host` was silently
dropped and every query arrived NAT'd.

**Generalisable:** a client address in a log that isn't from your subnet is
never the real client — it's whatever performed the last translation.
`172.17.x.x` means Docker. `10.42.x.x` will mean Kubernetes pods, and the
same confusion reappears when an ingress log shows every request coming from
one node IP.

### MinIO was archived mid-build

Between 10 and 12 September 2026 the `minio/` namespace was removed from
Docker Hub and `dl.min.io` began returning `410 Gone`. Community edition
became source-only with no pre-compiled releases.

Rather than pin a frozen dependency, I evaluated four replacements against a
requirement list derived from reading the OpenTofu backend source and the K3s
snapshot code — not from vendor compatibility tables.

The deciding requirement turned out to be conditional writes, and it had a
nasty property: **OpenTofu's `use_lockfile` never inspects the HTTP status
code.** Against a store that ignores `If-None-Match: *`, every caller gets a
200, every caller believes it holds the lock, and nothing warns you. That is
worse than no locking, because it looks like locking.

No one had published an end-to-end test of that behaviour against SeaweedFS,
so I measured it. Full reasoning and the result:
**[ADR-001 — Replacing MinIO](docs/adr/001-replacing-minio.md)**

### A privilege-dropping container and a read-only directory

SeaweedFS crash-looped with `Folder /data Permission: -r-xr-xr-x` /
`Not writable!`.

The image's entrypoint runs `chown -R seaweed:seaweed /data` and then drops
to uid 1000 via `su-exec`. `mkdir -p` inside a DSM shared folder had produced
mode `0555`, and **`chown` is not `chmod`** — the entrypoint fixed ownership
and left the mode alone, so uid 1000 ended up owning a directory it could not
write to.

Two things carried forward: a privilege-dropping image turns "does this path
exist" into "is it writable by that specific uid," and an entrypoint that
handles bind-mount *ownership* has not handled bind-mount *access*.

### The secret-scanner allowlist

A bait file containing `AKIAIOSFODNN7EXAMPLE` committed cleanly. That string
is AWS's canonical documentation key, and gitleaks allowlists it deliberately
— otherwise it would fire on every AWS tutorial on GitHub.

The guard was fine; the test was wrong. Re-tested with a private-key header,
which both `gitleaks` and `detect-private-key` caught. **An untested guard is
a decoration, and a test that cannot fail tests nothing.**

### macOS refused the connection and called it a routing failure

`tofu apply` failed repeatedly with `dial tcp 192.168.1.215:8006: connect: no
route to host`. Nothing was wrong with the network. A `ping` running
*concurrently with the failing apply* held 0% loss over 26 packets, `curl` to
the same host and port had returned 200 seconds earlier, Wi-Fi was off, there
was a single ARP entry, and the Proxmox NIC showed zero errors across 52
million packets.

macOS Local Network privacy returns `EHOSTUNREACH` when it blocks a connection
to an RFC 1918 address — no prompt, no log entry, and an error indistinguishable
from a real routing failure. The permission subject is the *running process*, so
the grant that already existed in System Settings did nothing until Terminal was
fully quit and relaunched.

**ICMP is not gated by it, so a clean ping does not exonerate the network — it
points at this.** That inversion is what cost the most time.

### The golden image carried a resolver nobody configured

Proxmox passed each VM exactly one nameserver. Inside them, `/etc/resolv.conf`
listed two, with the gateway first:

```
nameserver 192.168.1.1     # never configured anywhere
nameserver 192.168.1.250   # the one Phase 2 set up
```

`qm config` showed only `.250`, and NetworkManager was running with `dns=none
rc-manager=unmanaged`, so it was not writing the file at all. Two behaviours
combined: the Packer build ran on DHCP, so NetworkManager wrote the gateway into
`/etc/resolv.conf` and that file was baked into the template; and cloud-init's
RHEL path *updates* `/etc/resolv.conf` in place, adding servers that are missing
and removing nothing.

The ordering mattered because the gateway answers only for hosts in its own DHCP
lease table and returns NODATA for everything else — including
`nas.rookery.internal`. glibc treats NODATA as authoritative, so resolution of
the NAS was *intermittent*: identical lookups minutes apart returned an answer
once and nothing the next time. That name is the S3 endpoint RKE2 uses for etcd
snapshots.

Fixed with `truncate -s 0 /etc/resolv.conf` in the template generalization
step — alongside the machine-id and SSH host key removal — and a `sed` across
the eight existing VMs. **A resolver that works most of the time is worse
than one that never works — it fails later, under load, disguised as something
else.**

### Provider defaults overwrote what the template already had

The first plan contained `+ bios = "seabios"` and `+ scsi_hardware =
"virtio-scsi-pci"` — attributes never written in the config. Template 9002 is
OVMF on q35, so `seabios` would have produced eight VMs that never booted, and
the cause would have looked like a broken template rather than a provider
default.

**In a plan, a `+` on an attribute you never wrote is not noise. It is the
provider telling you what it is about to decide on your behalf.**

### Shared storage does not make a template node-independent

Five of eight clones failed with `unable to find configuration file for VM 9002
on node 'pve-3'`. A VM's config lives at
`/etc/pve/nodes/<node>/qemu-server/9002.conf` and belongs to exactly one node.
Shared storage holds the template's *disks*; it does not move the *config*. The
clone must be initiated on the owning node with the other as target — `node_name`
inside the `clone` block is the source, the resource's own `node_name` is the
destination.

The clones that did target the right node failed differently: `cfs-lock
'storage-pve-nfs' error: got lock request timeout`. OpenTofu's default
parallelism is 10, and Proxmox serializes storage operations behind a
cluster-wide lock, so seven concurrent full clones exhausted it. Fixed with
`-parallelism=2` and `retries = 3` in the clone block.

**Both errors say "lock" and neither involved the state lock.** Identifying
which layer an error came from was most of the diagnosis.

### `prevent_destroy` paid for itself

Adding `node_name` to the `clone` block turned the next plan into **8 to add, 3
to destroy**. The provider treats `clone` as part of the resource's identity, so
changing it forces replacement — of three VMs that were already built correctly,
in order to alter a field describing an event that had already happened.

`prevent_destroy` refused the plan instead of executing it. The fix was
`ignore_changes = [clone]`, since a clone is creation-time only and drift on it
is meaningless.

**A guard rail that has never fired is not evidence that it was unnecessary.**
---

## Repository layout

| Repo | Owns |
|---|---|
| **homelab-infra** (this one) | OpenTofu, Ansible, decision records, recovery runbook |
| [homelab-fleet](https://github.com/georgepoe2/homelab-fleet) | Everything inside the cluster, reconciled by Flux |
| [homelab-apps](https://github.com/georgepoe2/homelab-apps) | Application source and Helm charts |

### Guard rails

Both `pre-commit` and CI run the same hook set from the same config file, so
the two cannot drift. CI additionally scans **full git history** with
`fetch-depth: 0` — a secret committed and later deleted is still in the
object store of a public repo, which pre-commit structurally cannot see.

---

## Recovery

[`docs/restore.md`](docs/restore.md) — secret inventory, age and CA key
recovery, credential rotation. Written to be read under stress on a machine
that isn't the one that built this.

Two of those secrets are genuinely unrecoverable if lost: the age key and the
CA private key. Both are held in three places, one of them offsite and
passphrase-encrypted, and the offsite copy has been tested by decrypting from
it rather than assumed to work.

---

## Roadmap

- Phase 6 — RKE2 with kube-vip, CNI chosen deliberately
- Phase 7 — Flux, MetalLB, ingress-nginx, cert-manager, NFS CSI
- Phase 8 — restore an etcd snapshot, destroy and rebuild the whole cluster
  twice, drive a minor-version upgrade with zero dropped requests

Later: Packer for the golden image, step-ca replacing the static CA,
blackbox_exporter replacing the certificate monitor script.
