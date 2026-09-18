# ADR-002 — Cilium as the CNI, with kube-proxy replacement

**Status:** Accepted
**Date:** 2026-09-18
**Supersedes:** nothing
**Context:** Phase 6, decided before first boot of the cluster

## Context

RKE2 installs a CNI at first boot and writes the choice into cluster state.
Changing it afterwards is a rebuild, not a reconfiguration, so this had to be
decided before `k8s-cp-1` started for the first time.

RKE2 was chosen over vanilla Kubernetes and K3s for its security posture: CIS
benchmark hardening, FIPS-validated cryptography, SELinux support. Taking the
default CNI underneath that choice would have left the posture argument
resting entirely on defaults nobody selected.

## Options

| | Canal (default) | Calico | Cilium |
|---|---|---|---|
| Datapath | iptables | iptables/eBPF | eBPF |
| Policy model | IP-based | IP-based + tiers | **identity-based** |
| kube-proxy | required | required | **replaceable** |
| Flow visibility | none built in | limited | **Hubble** |
| Node-to-node encryption | no | WireGuard | WireGuard |
| Risk | lowest | low | moderate |

## Decision

**Cilium**, with `kubeProxyReplacement: true`.

RKE2 ships Cilium as a first-class packaged chart (`cni: cilium`), so this is
a supported configuration rather than a hand-rolled install. Rocky 9's 5.14
kernel is comfortably past the 5.8 floor for kube-proxy replacement.

Cilium is **not inherently more secure than Canal** — both can enforce
NetworkPolicy. What it provides is policy that is identity-based rather than
IP-based, so it survives pod churn; L7-aware rules; and Hubble, which shows
what is actually flowing. It is more *enforceable* and far more *observable*.

That distinction creates an obligation: **if Phase 7 ships without network
policies, the security argument for this decision is hollow.** Default-deny in
at least one namespace, plus a Hubble flow showing a blocked connection, is
what converts the choice into evidence.

## Consequences

### The API server is reached at localhost, not the VIP

`kubeProxyReplacement` needs the API server before cluster networking exists.
RKE2 runs a per-node load balancer on `127.0.0.1:6443`, so the documented
values are `k8sServiceHost: "localhost"`, `k8sServicePort: "6443"`. The
kube-vip VIP is not involved, which removes what looked like a bootstrapping
circularity.

### The NetworkManager exclusion is ours, not the vendor's

RKE2's known-issues page documents a NetworkManager `unmanaged-devices` config
for Canal only — `flannel*`, `cali*`, `tunl*` and friends. There is no
published Cilium equivalent. `ansible/baseline.yml` writes `rke2-cilium.conf`
covering `cilium_*` and `lxc*` by extrapolation from the Canal guidance, and
removes the Canal file. This is our inference, not documented vendor advice.

### rp_filter needs no management

Cilium's agent ships a `sysctlfix` init container that writes
`/etc/sysctl.d/99-zzz-override_cilium.conf` itself. Phase 3 deferred the
rp_filter decision to Phase 6; it resolves to "do nothing, verify afterwards."

### The control-plane taint and the CNI are coupled

RKE2's hardening guidance says to keep workloads off control planes with
`CriticalAddonsOnly=true:NoExecute`. RKE2's packaged Cilium chart tolerates
seven taints — control-plane, etcd, master, agent-not-ready,
cloudprovider-uninitialized, not-ready, unreachable — and **not that one**.

On a cluster that already has workers this is invisible. During single-node
bootstrap it is fatal: the operator cannot schedule, so it never registers its
nine CRDs, so every cilium-agent blocks on
`Still waiting for Cilium Operator to register CRDs`, so there is no CNI, so
CoreDNS never gets an IP. The cluster presents as "Cilium is broken" rather
than "your taint is unschedulable."

Both choices are individually documented and individually correct. The
interaction is undocumented.

Fixed by overriding `operator.tolerations` in the `rke2-cilium`
HelmChartConfig. Helm **replaces** a list rather than merging it, so the
chart's original seven are repeated verbatim alongside the eighth — supplying
only `CriticalAddonsOnly` would have silently dropped
`node.cilium.io/agent-not-ready`, producing a different scheduling failure
later, during node bootstrap, when that toleration is the one that matters.

### Verified on this build

- `KubeProxyReplacement: True [eth0 ... (Direct Routing)]`
- No kube-proxy container on any node
- `cilium status --brief` → `OK` across all eight nodes
