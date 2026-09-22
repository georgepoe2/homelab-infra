# ADR-003 — Cilium Gateway API and Cilium LB-IPAM, replacing ingress-nginx and MetalLB

**Status:** Accepted
**Date:** 2026-09-22
**Context:** Phase 7, decided before `flux bootstrap`
**Related:** ADR-002 (Cilium as the CNI)

## Context

The original plan for Phase 7 was ingress-nginx behind MetalLB, both managed by
Flux, with ingress-nginx claiming `192.168.1.235`.

**ingress-nginx retired in March 2026.** The Kubernetes project ended
maintenance: no further releases, no bugfixes, and no security patches.
Existing installs keep running and the images remain downloadable, but a newly
disclosed vulnerability will not be fixed.

Installing it now would put an unmaintained, unpatchable component at the
internet-facing edge of a cluster whose entire design argument is security
posture — RKE2 over vanilla Kubernetes, the CIS profile, Cilium over Canal.
It would also be a poor answer to an obvious interview question.

Kubernetes' own recommendation is Gateway API.

## Decision

**Gateway API, implemented by Cilium.** And, separately,
**Cilium LB-IPAM with L2 announcements in place of MetalLB.**

Both were already present. The nine CRDs the Cilium operator registers at
startup include `ciliumloadbalancerippools.cilium.io` and
`ciliuml2announcementpolicies.cilium.io` — visible in this cluster's own agent
log during the Phase 6 bootstrap. Gateway API support needs
`kubeProxyReplacement`, which ADR-002 already enabled.

### Why not Traefik

RKE2 ships it and it is actively maintained, so it was the low-risk answer.
Rejected because it adds a second data path alongside Cilium's for no capability
Cilium lacks, and because re-enabling RKE2's bundled chart hands ingress back to
RKE2's deploy controller — the conflict Phase 6's `disable:` list exists to
prevent. Deploying Traefik through Flux instead would work, but then it is
simply another component with no reason to be there.

### Why not MetalLB

Ordinary and well known, and the runbook was written for it. Rejected because
it duplicates a capability Cilium already has, and because its speaker needs
`hostNetwork` and `NET_RAW` — under the CIS profile's restricted Pod Security
admission that means an explicit namespace exemption. Cilium's agent already
runs privileged in `kube-system`, which the CIS profile exempts, so the same
job costs nothing extra.

The stack ends up with Cilium doing CNI, kube-proxy replacement, load-balancer
IP allocation, L2 announcement, Gateway API and network policy. That is one
system to understand deeply rather than five to integrate.

## The version constraint — do not skip this

**Cilium 1.19.6 requires Gateway API CRDs v1.4.1.**

Not the version the current Cilium website documents. docs.cilium.io serves only
the newest release's guidance, which at time of writing says v1.6.1 — correct
for Cilium 1.20, wrong here. The v1.19.6 figure comes from Cilium's own
documentation source at the `v1.19.6` tag.

**Gateway API v1.5.0 or newer actively breaks Cilium 1.19.x.** TLSRoute was
promoted from `v1alpha2` to `v1` in Gateway API 1.5.0; Cilium's operator in
versions >= 1.19.2 and < 1.20.0 still indexes the alpha kind, and fails to
start:

```
failed to create gateway controller: failed to setup reconciler:
failed to setup field indexer "backendServiceTLSRouteIndex":
no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1alpha2"
```

The consequence is the failure mode already seen once in Phase 6: an operator
that will not start never registers its CRDs, every cilium-agent blocks waiting
for them, and the cluster loses its CNI entirely. Pin v1.4.1, and re-check the
pairing before any Cilium upgrade.

## Consequences

### Ordering

The Gateway API CRDs must exist **before** the Cilium operator restarts with
`gatewayAPI.enabled=true`. CRDs first, Helm values second.

### Cilium's configuration stays in Ansible, not Flux

RKE2's deploy controller owns the `rke2-cilium` chart and reconciles it
continuously. Enabling Gateway API, L2 announcements and the raised client rate
limit are changes to that chart's values, so they belong in the
`HelmChartConfig` that Ansible renders — not in the Flux repo. Flux owns what
runs *inside* the cluster; the CNI is part of the cluster itself.

This is the layer boundary the README already claims, landing on the right side
of an awkward case.

### The API server client rate limit must be raised

L2 announcements hold a lease per announced service, renewed continuously.
Cilium's default client rate limit is 5 QPS with bursts to 10, which the
documentation states is "quickly reached" under L2 announcements. Sized by
`QPS = #services * (1 / leaseRenewDeadline)`.

### Gateway API is a different resource model

`Gateway` plus `HTTPRoute` rather than `Ingress`, with routing rules separated
from listener configuration. Fewer copy-paste examples exist. This is a real
cost, accepted because the alternative is adopting the spec Kubernetes is
migrating away from.

Cilium only programs Gateways whose class is `cilium`, so the `GatewayClass`
must be named exactly that.

## What actually happened on this build

Two things that the theory above did not predict.

### The wrong CRDs were already installed, by a component we had removed

Enabling this was expected to start with installing Gateway API v1.4.1. The
apply failed instead, on a server-side apply conflict:

```
error: Apply failed with 2 conflicts: conflicts with "helm":
- .metadata.annotations.api-approved.kubernetes.io
- .metadata.annotations.gateway.networking.k8s.io/bundle-version
```

The CRDs already existed. They had been installed on 18 September at 18:17 by
`rke2-traefik-crd` — Traefik's CRD chart, during the Phase 6 bootstrap, before
Traefik was disabled. They carried `helm.sh/resource-policy: keep`, so when
`helm-delete-rke2-traefik-crd` ran they deliberately survived the uninstall.
The release was gone; the CRDs remained, owned by nothing.

They were **Gateway API v1.5.1, standard channel**, with TLSRoute serving `v1`
only and `v1alpha2` set to `served: false`. Precisely the configuration that
crashes Cilium 1.19's operator. Enabling Gateway API at that moment would have
taken the CNI down on all eight nodes.

`--force-conflicts` was the tempting fix and the wrong one: it seizes field
ownership from a Helm release rather than resolving anything. Since no Gateway
API objects existed anywhere in the cluster, the right move was to delete all
eight orphaned CRDs and reinstall at v1.4.1, at which point nothing contests
ownership.

**`helm.sh/resource-policy: keep` means uninstalling a chart can leave cluster-
scoped objects behind that constrain unrelated components months later.**
Disabling `rke2-traefik` removed Traefik. It did not remove Traefik's opinion
about which Gateway API version this cluster runs.

### A values-only change does not restart anything

After the chart upgraded, everything reported success. The helm job completed,
`cilium-config` showed `enable-gateway-api: true` and
`enable-l2-announcements: true`, and the GatewayClass existed. It sat at
`ACCEPTED: Unknown` for ten minutes.

The cause was in one column of unrelated output: the Cilium pods were `4d1h`
old. **RKE2's `rke2-cilium` chart puts no config checksum on the pod template**,
so a values-only change updates the ConfigMap and leaves every pod running with
its old flags in memory. The chart created the GatewayClass; the operator that
would accept it was still the process that started four days earlier.

`ansible/cilium-gateway.yml` now restarts the operator and the DaemonSet
explicitly, guarded on the config having actually changed. Note that both
restarts are needed and for different reasons: `enable-gateway-api` is read by
the operator, `enable-l2-announcements` by the agent.

**Every layer reported success. The only thing that told the truth was a pod's
age.** This is the third instance on this build of a green status meaning "the
configuration is correct" rather than "the thing is running" — after
`use_lockfile` failing open and `etcd-s3-bucket-lookup-type: auto` uploading
nothing. Which is why this play's final check is the GatewayClass reporting
`Accepted`: that condition cannot be satisfied without a working controller.

## Verified on this build

- Gateway API v1.4.1 installed; TLSRoute serves `v1alpha2` from the
  experimental channel
- `GatewayClass cilium` — `ACCEPTED: True`
- `KubeProxyReplacement: True`, `Proxy Status: OK ... Envoy: embedded`
