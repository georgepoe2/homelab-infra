# Rookery: homelab Kubernetes platform, built systematically.

Attempting to improve my knowledge and understanding of K8s. Pulled together a Homelab made from three mini-PCs, an old M1 Mac mini we've used as a personal computer for years, and the Synology NAS I've been using for home storage for several years.

Most of the basic setup was chosen from YouTube research and Claude AI recommendations to get me to a point where I could learn to deploy, manage, and troubleshoot containers in the environment.

This ended up being Proxmox on the miniPCs, the Mac acting as my workstation, and Several infrastructure pieces running in Container Manager on the NAS.

I utilized Claude to write the documentation and first drafts of most of the configurations. I chose the hardware and the tools, ran everything, and did the debugging including catching several of Claude's mistakes sometimes repetitively. He really likes putting ! Inside double quotes. Every measurement and error message in here came off my command outputs.

---

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
| 6 — RKE2 cluster | ✅ Complete — failover measured at ~10 s |
| 7 — Flux and the platform layer | 🚧 In progress — GitOps, Gateway API and network policy live; cert-manager and CSI outstanding |
| 8 — Operate: restore, rebuild, upgrade | 🚧 In progress — etcd snapshot restore drilled end to end; rebuild and upgrade outstanding |

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
                 Cilium LB-IPAM  .235 → Gateway API
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
### Two hypervisors lost their NICs four minutes apart, and the cluster did not notice

Installing RKE2 on all four workers at once put two simultaneous multi-GB image
pulls through pve-1's single 1 GbE link and one through pve-2's. Both hosts
stopped transmitting:

```
e1000e 0000:80:1f.6 nic0: Detected Hardware Unit Hang
```

The hosts stayed alive — load average 0.27, no OOM, the power button still
worked. They simply could not transmit, so every VM on them went dark,
`pve-nfs` went "not online", and corosync dropped them.

The corosync log on the surviving node dates it precisely. pve-1's link
recovered at 14:35:52 and wedged again 26 seconds later, which is the driver
resetting the adapter and the same load immediately re-wedging it. pve-2
followed at 14:39:07. **The failure order matches the load order exactly:** two
workers installing on pve-1, one on pve-2, one on pve-3, which survived.

All three hosts run the same `e1000e` NIC, so pve-3 was lucky rather than
different. Mitigated with a systemd unit disabling offloads on each host, and
by serialising the Ansible play so only one image pull per host runs at a time.
The `serial: 1` on `rke2-agent.yml` is a **hypervisor** constraint, not a
cluster one — agents joining an established cluster contend for nothing.

What this bought: an unplanned and unannounced version of the Phase 8 control
plane failure drill. Two of three hypervisors dropped out within four minutes,
taking one control plane and two workers with them, and **etcd held quorum, the
kube-vip VIP failed over, and the surviving nodes kept serving.** After the
hosts came back, `etcdctl endpoint health --cluster` reported all three members
healthy with no intervention.

The latent fault was always going to surface during Phase 8's rebuild, when
eight VMs are destroyed and recreated and all of them pull images at once —
mid-drill, with no baseline for what "working" looks like.

### RKE2 1.36 ships Traefik, not ingress-nginx

The runbook said to disable `rke2-ingress-nginx` so Flux could own the ingress
controller. That component does not exist in this version. Listing
`/var/lib/rancher/rke2/server/manifests` during unrelated debugging showed
`rke2-traefik.yaml` — so the config had been disabling something absent while
leaving the real controller in place, and would have applied cleanly, reported
success, and produced two controllers fighting over ingress in Phase 7.

**Configuration that succeeds at doing nothing is the recurring theme of this
build** — alongside `use_lockfile` failing open and
`etcd-s3-bucket-lookup-type: auto` silently uploading nothing.

### The nodes preferred an address family they could not route

`curl` and `dnf` intermittently failed with `No route to host` reaching
`rpm.rancher.io`. Both A and AAAA records resolve; the VMs have no global IPv6
address. glibc's built-in RFC 3484 table ranks native IPv6 above IPv4-mapped,
so `getaddrinfo` handed out an unreachable address — sometimes. The control
planes drew IPv4 and installed fine; a worker drew IPv6 and failed.

A non-deterministic failure that a retry appears to fix is worse than a
consistent one. Fixed at the source with `precedence ::ffff:0:0/96 100` in
`/etc/gai.conf`, which applies to every program on the node, rather than adding
`--ipv4` to each caller as it fails.
### The deliberate failover drill

After the involuntary version, the planned one. The control plane holding the
kube-vip lease (`k8s-cp-3`) was hard-stopped with `qm stop` — no graceful
shutdown, no chance to release the lease — while a loop polled the API through
the VIP once a second:

```
10:14:29 401          <- last answer from cp-3
10:14:30 TIMEOUT
10:14:33 TIMEOUT      lease still reads cp-3 until 10:14:36:
10:14:36 TIMEOUT      a dead holder's lease is not cleared, it expires
10:14:39 401          <- cp-2 took the lease at 10:14:38
```

**About ten seconds** from power-off to the API answering through the VIP,
inside what the 5 s lease duration predicts. etcd held quorum at two of three
throughout (`context deadline exceeded` on the dead member only), and the node
rejoined on restart with no manual steps.

(`401` is the healthy answer here: the CIS profile disables anonymous auth, so
an unauthenticated `/healthz` is refused rather than served.)
### github.com resolved to my ingress VIP

Flux bootstrapped, pushed its manifests, and then sat waiting for the
in-cluster source-controller to clone the repo back. The log:

```
unable to clone 'ssh://git@github.com/georgepoe2/homelab-fleet':
dial tcp 192.168.1.235:22: connect: no route to host
```

`192.168.1.235` is the ingress address. `github.com` had resolved to it.

Pods get `options ndots:5` and a search list ending in `rookery.internal`.
`github.com` has one dot, fewer than five, so the resolver tried every search
suffix first — including `github.com.rookery.internal`. AdGuard's wildcard
`*.rookery.internal -> 192.168.1.235` answered, the resolver took the first
answer it got, and dialled the ingress VIP on port 22.

So from inside the cluster, **every external hostname with fewer than five dots
resolved to the ingress address**. Not just GitHub — every image registry,
every API. Flux was simply the first workload to try reaching the outside
world.

Fixed by deleting the wildcard. Each application now gets its own rewrite,
which is a few seconds per app. The alternatives — scoping the wildcard to a
subdomain, or pointing kubelet at a resolv.conf without the search domain —
both leave a zone that answers for every name under it, and it will end up in
someone's search path again.

I had flagged this wildcard four days earlier, when it made every node name
resolve to the ingress LB. It was a footgun then. Once anything inside the
cluster needed the internet it was a wall.

### Stopping the service did not stop the cluster

Symptom: all three `rke2-server` services reported `inactive`, and `kubectl`
from my laptop kept answering.

`systemctl stop rke2-server` stops the supervisor and the kubelet. It does not
stop the static pods. Those run as containerd shim children that get reparented
to PID 1, so etcd, kube-apiserver and kube-controller-manager stayed up with
uptimes from the day the node was built:

```
etcd  2351  Sep18  etcd --config-file=/var/lib/rancher/rke2/server/db/etcd/config
root  5205  Sep18  kube-apiserver --advertise-address=192.168.1.221 ...
```

That matters, because `rke2 server --cluster-reset` wants sole use of the etcd
data directory and ports 2379/2380. Running it with the old etcd still holding
them puts two processes on one database.

**Fix:** `rke2-killall.sh` is the real stop. On an RPM install it lives in
`/usr/bin`, not `/usr/local/bin`, and `rke2-uninstall.sh` sits beside it one
tab-completion away. `rpm -ql rke2-common` is how to find them rather than
guessing.

I only caught this because the API kept answering after I thought I'd stopped
everything, and that looked wrong. Trusting `systemctl` would have meant
running the reset into a live database.

### An address left behind reported itself as an etcd failure

After the restore, cp-2 refused to rejoin:

```
Error: preparing server: failed to bootstrap cluster data:
Get "https://192.168.1.201:9345/v1-rke2/server-bootstrap":
dial tcp 192.168.1.201:9345: connect: connection refused
```

The message blames cluster data. The fault was a leftover IP address.

kube-vip assigns the VIP by adding it to `eth0` on whichever server holds the
lease, and `rke2-killall.sh` kills the pod without removing the address. cp-2
had been the holder, so `192.168.1.201/32` was still on its own NIC:

```
cp-2   eth0   192.168.1.222/24  192.168.1.201/32    <- orphan, nothing listening
cp-1   eth0   192.168.1.221/24  192.168.1.201/32    <- live, rke2 on 9345
```

Refused rather than timed out, because cp-2's request to the VIP never left the
box. One command cleared it:

```
ip addr del 192.168.1.201/32 dev eth0
```

**Fix in the runbook:** after killall, run `ip -4 -br addr show` on every server
and delete the VIP anywhere other than the node you are restoring from. Only the
last lease holder carries it — cp-3 was clean.

### A restored cluster shows you the past and calls it the present

With cp-1 back up alone, `kubectl get nodes` listed cp-2 and cp-3 as `Ready`.
Both were powered down with their containers killed. Node conditions are rows in
etcd like anything else, so the snapshot restored their 09:36 state along with
everything else, and the node-lifecycle controller needed a heartbeat timeout to
notice. The kube-vip pods read `Running` on all three nodes for the same reason.

Anything that reads status straight after a restore is reading history. The
90-second wait before believing `get nodes` is now a step in the runbook.


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

The restore was exercised rather than assumed on 25 September 2026. A marker
object Flux does not manage was planted, snapshotted to the NAS, deleted from a
live API, and came back from `--cluster-reset` with its original UID and
resourceVersion — which is what proves etcd was restored and not that GitOps
re-applied something. Eighteen minutes end to end, about three of them with no
API at all. What it turned up is in *What broke*, above.

---

## Roadmap

- Phase 7 — Flux, Cilium LB-IPAM, Gateway API, cert-manager, NFS CSI
- Phase 8 — destroy and rebuild the whole cluster twice, drive a minor-version
  upgrade with zero dropped requests (etcd snapshot restore: done 25 Sep 2026)

Later: Packer for the golden image, step-ca replacing the static CA,
blackbox_exporter replacing the certificate monitor script.
