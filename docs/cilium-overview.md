# Cilium in this cluster — what it does and who it works with

Written 2026-09-22, after Phase 7's networking layer went in.
Companion to [ADR-002](adr/002-cilium-as-cni.md) (why Cilium) and
[ADR-003](adr/003-gateway-api-over-ingress.md) (Gateway API and LB-IPAM).

## What Cilium is

A CNI plugin — the thing Kubernetes calls to give a pod a network. What makes
Cilium different is *where* it does the work: it compiles **eBPF programs and
loads them into the Linux kernel** rather than writing iptables rules. Packets
are handled by kernel code generated for this specific cluster, which is why it
can replace kube-proxy outright and inspect traffic at the HTTP layer without a
sidecar.

Here it ended up doing five jobs that are usually five separate projects.

## The five jobs

```
┌─────────────────────────────────────────────────────────────────┐
│  CILIUM                                                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Pod networking (CNI)      every pod gets an IP from          │
│                               10.42.0.0/16, routed node-to-node  │
│                                                                  │
│  2. Service load balancing    replaces kube-proxy entirely.      │
│     (kubeProxyReplacement)    ClusterIP/NodePort resolved in     │
│                               eBPF, not iptables                 │
│                                                                  │
│  3. Network policy            allow/deny by workload IDENTITY,   │
│                               not by IP - survives pod churn     │
│                                                                  │
│  4. LoadBalancer IPs          hands out 192.168.1.235 and        │
│     (LB-IPAM + L2)            answers ARP for it   <- was MetalLB│
│                                                                  │
│  5. Gateway API               HTTP routing into the cluster,     │
│     (embedded Envoy)          via its own Envoy  <- was nginx    │
│                                                                  │
│  + Hubble                     flow visibility: what talked to    │
│                               what, and what got dropped         │
└─────────────────────────────────────────────────────────────────┘
```

Jobs 4 and 5 were decided in Phase 7 (ADR-003). The rest came from Phase 6.

## The two moving parts

Cilium is only two workloads, and knowing which does what explains most of the
debugging this build has needed.

```
   ┌──────────────────────────────────────────────────────────┐
   │  cilium-operator          Deployment, 2 replicas          │
   │                           (cluster-wide brain)            │
   │                                                           │
   │   . registers Cilium's 9 CRDs                             │
   │   . allocates a pod CIDR to each node (IPAM)              │
   │   . garbage-collects stale identities and endpoints       │
   │   . runs the GATEWAY API CONTROLLER                       │
   │       - reads Gateway + HTTPRoute, programs the agents    │
   └──────────────────────────────────────────────────────────┘
                              │
                 tells agents what to enforce
                              v
   ┌──────────────────────────────────────────────────────────┐
   │  cilium-agent             DaemonSet, one per node         │
   │                           (per-node muscle)               │
   │                                                           │
   │   . loads eBPF programs into THIS node's kernel           │
   │   . assigns pod IPs on this node                          │
   │   . enforces policy for pods on this node                 │
   │   . ANSWERS ARP for LoadBalancer IPs  <- L2 announcements │
   │   . runs the embedded ENVOY for L7 / Gateway API          │
   └──────────────────────────────────────────────────────────┘
```

This split is why both had to be restarted when Gateway API was enabled, for
different reasons:

- `enable-gateway-api` is read by the **operator**. Without its restart the
  GatewayClass sat at `ACCEPTED: Unknown`.
- `enable-l2-announcements` is read by the **agent**. Without its restart
  nothing would ever answer ARP for `192.168.1.235`.

It is also why the operator being unschedulable in Phase 6 was fatal: no
operator, no CRDs registered, every agent blocks at startup, no CNI anywhere.

## How a request actually flows

Someone on the LAN opens `grafana.rookery.internal`:

```
  Browser
     │
     │ 1. who is grafana.rookery.internal?
     v
  AdGuard Home  (192.168.1.250)
     │             explicit rewrite -> 192.168.1.235
     │             (no wildcard: it swallowed every external name too)
     │ 2. "192.168.1.235"
     v
  Browser: who has 192.168.1.235?   -- ARP broadcast on the LAN --+
                                                                  │
     +------------------------------------------------------------+
     │ 3. a cilium-agent on ONE worker answers with its own MAC
     │    (CiliumL2AnnouncementPolicy decides which nodes may)
     v
  k8s-work-2  (192.168.1.225)
     │
     │ 4. packet hits eBPF at the network interface,
     │    recognised as a LoadBalancer IP for the Gateway's Service
     v
  embedded Envoy  (inside that node's cilium-agent)
     │
     │ 5. terminates TLS, reads the HTTP Host header,
     │    matches an HTTPRoute: grafana.rookery.internal -> svc/grafana
     v
  backend pod  (10.42.x.y - possibly on a DIFFERENT node)
     │
     │ 6. eBPF forwards it there directly - no kube-proxy,
     │    no iptables chain, no extra hop through a proxy pod
     v
  Grafana answers
```

Two things worth noticing. **Step 3 is what MetalLB used to do** — there is no
MetalLB, because the CNI agent already sits on the wire and can answer for the
address. And **step 6 is the eBPF payoff**: with kube-proxy every packet
traverses a chain of iptables rules; here the destination is resolved by a
kernel program in constant time.

## What Cilium does NOT do

| Concern | Owner | Why not Cilium |
|---|---|---|
| Control-plane VIP `.201` | **kube-vip** | Must work before the cluster exists. Cilium needs a running API server; kube-vip is what makes the API server reachable. kube-vip runs with `svc_enable: false` precisely so the two never both answer ARP for service IPs. |
| DNS for `rookery.internal` names | **AdGuard Home** on the NAS | Outside the cluster on purpose — Phase 8 destroys the cluster, and name resolution has to survive that. |
| Certificates | **cert-manager** + the internal CA | Cilium terminates TLS; it does not issue the certificate. |
| In-cluster DNS | **CoreDNS** | Cilium carries packets to it. |
| Storage | **NFS CSI** to the Synology | Unrelated layer. |

## Who manages Cilium itself

```
  RKE2  --ships and reconciles-->  rke2-cilium Helm chart
    ^                                      ^
    │                                      │ values
  Ansible --renders HelmChartConfig--------+
  (homelab-infra)                   /var/lib/rancher/rke2/server/manifests/

  Flux    --manages-->  the OBJECTS Cilium consumes:
  (homelab-fleet)         CiliumLoadBalancerIPPool
                          CiliumL2AnnouncementPolicy
                          Gateway, HTTPRoute
                          CiliumNetworkPolicy
```

**Configuring Cilium is Ansible's job; using Cilium is Flux's job.** RKE2's
deploy controller reconciles that chart forever, so if Flux also managed it the
two would overwrite each other indefinitely — the same conflict the Phase 6
`disable:` list exists to prevent.

## The version coupling

RKE2 1.36.4 pins Cilium 1.19.6, which pins Gateway API v1.4.1. Those three move
together or the operator refuses to start — see ADR-003 for the specific
failure and why v1.5.0+ breaks it.
