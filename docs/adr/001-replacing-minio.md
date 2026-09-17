# ADR-001 — Replacing MinIO

- **Status:** Decided and verified
- **Date:** 2026-09-14
- **Affects:** object store, OpenTofu state backend, RKE2 etcd snapshots

## Context

MinIO's community edition was archived partway through this build.

**June 2025** — the admin console was removed from Community Edition. The web
UI became a login page with essentially nothing behind it. Survivable; it
only changed how a checkpoint was written.

**10–12 September 2026** — distribution was withdrawn. The `minio/` namespace
disappeared from Docker Hub and `dl.min.io` began returning `410 Gone` for
every binary path. MinIO's stated position is that the community edition is
now distributed as source code only, with no pre-compiled releases.

Images still exist on `quay.io/minio/minio`. Quay is operated by Red Hat, is
not maintained by MinIO, and no commitment has been made about those images.
The honest read is that they survive by inertia.

Pinning a tag and mirroring it is a legitimate response to a frozen
dependency — for a dependency there is a reason to keep. There wasn't one
here. The replacement cost was a few hours in a lab that had not yet written
a line of OpenTofu against the endpoint.

## Requirements

Two consumers, using a small and specific slice of the S3 API. This list was
derived by reading the OpenTofu backend source and the K3s snapshot code, not
from vendor compatibility tables.

**Both consumers need**

- `PutObject`, `GetObject`, `HeadObject`, `DeleteObject`
- `ListObjectsV2` with prefix and pagination
- Path-style addressing and SigV4

**RKE2 etcd snapshots additionally need**

- `HeadBucket` — a hard gate at client startup; the uploader refuses to
  initialise without it
- **Multipart upload.** The uploader calls `FPutObject` without a part size,
  so minio-go switches to multipart at 16 MiB. A store without multipart
  works on an empty cluster and breaks later — the worst possible failure
  timing.
- **`x-amz-meta-*` user metadata surviving a `PutObject` → `HeadObject` round
  trip.** Cluster ID, node name and token hash are written as user metadata
  and read back to reconcile snapshots.

**OpenTofu additionally needs**

- Typed `NotFound` / `NoSuchBucket` errors on `HeadObject` — the backend
  calls `HeadObject` before `GetObject` specifically to work around
  S3-compatible stores that mishandle a missing object
- Tolerance of AWS checksum headers, or `skip_s3_checksum`
- **Only for state locking:** `PutObject` honouring `If-None-Match: *` with a
  412 when the object exists

**Neither needs** bucket versioning, object lock, DynamoDB, STS/IAM/IMDS,
server-side encryption, lifecycle rules, or bucket policies.

## The deciding requirement

OpenTofu 1.10 added `use_lockfile`, replacing the DynamoDB table with a lock
object written next to the state under a `.tflock` suffix:

```go
putParams := &s3.PutObjectInput{
    Bucket:      aws.String(c.bucketName),
    Key:         aws.String(c.lockFilePath()),
    Body:        bytes.NewReader(lInfo),
    IfNoneMatch: aws.String("*"),
}
_, err := c.s3Client.PutObject(ctx, putParams, ...)
if err != nil {
    // ... only here does it conclude the lock is held by someone else
}
```

The intended contract is 200 = acquired, 412 = held by someone else.

**But OpenTofu never inspects the status code.** It tests `err != nil` and
nothing else — there is no reference to `PreconditionFailed`, `412` or
`HTTPStatusCode` anywhere in the s3 backend.

So against a store that ignores `If-None-Match` and simply overwrites, every
caller's PutObject succeeds, every caller believes it holds the lock, and
there is no error, warning or diagnostic anywhere. `use_lockfile = true` on
such a store is **worse than no locking, because it looks like locking**.

OpenTofu's own RFC says the quiet part out loud: when using an S3-compatible
provider, "it needs to be checked that the provider supports conditional
writes in the same way Amazon S3 is offering." Nothing checks it for you.

## Options considered

| | SeaweedFS 4.46 | Garage v2.4.1 | RustFS 1.0.0-rc.6 | Ceph RGW |
|---|---|---|---|---|
| Licence | Apache-2.0 | AGPLv3 | Apache-2.0 | LGPL |
| Conditional writes | **Yes** | **No — by design** | Yes | Unverified |
| Bucket versioning | Yes | No | Yes | Yes |
| Measured RAM | <200 MB | 80–120 MB | consumed its limit | GB per daemon |
| Docs ask for | — | 1 GB | 128 GB production | 4 GB/OSD |
| Ever shipped GA | Yes | Yes | **No** | Yes |
| Fits this hardware | **Yes** | Yes | No | No |

**Garage** was the hardest to reject — smallest footprint, NLnet reliability
grant, real production users, coverage in LWN. But its own known-issues page
states conditional writes are "structurally impossible to implement in Garage
due to the lack of a consensus algorithm, which is one of Garage's core
design choices which we cannot reconsider." Combined with no object
versioning, it would have given this lab a state backend with neither locking
nor history.

**RustFS** implements conditional writes and is CI-gated against the Ceph
s3-tests suite. Disqualified on hardware: its own documentation asks for 2 GB
minimum for test environments and 128 GB for production, against a NAS with
under 4 GB total that also serves DNS and NFS. It has also never shipped a GA
release, marks distributed mode "under testing", and has open
metadata-corruption reports.

**Ceph RGW** is the right answer to a different question. Proxmox ships Ceph
integration, but `pveceph` manages monitors, managers, OSDs, pools, RBD and
CephFS — **not** the RADOS Gateway, which is a manual install outside
everything Proxmox will upgrade or repair. And ~4 GB per OSD plus monitor,
manager and gateway daemons is wildly out of proportion to one kilobyte-scale
state file. If Ceph ever enters this lab it should be as RBD replacing
local-LVM for VM storage — a real architectural upgrade — with S3 as a cheap
add-on to a cluster that already exists.

## Decision

**SeaweedFS**, single container on the Synology via `weed mini`, bucket
versioning off.

Conditional writes landed in release 3.97 (September 2025) and the
implementation is in the Apache-2.0 tree, not an enterprise build. It returns
a real 412, and it is atomic rather than check-then-write: creates are routed
to the object's owner filer, whose per-path lock serialises them.

**Versioning is deliberately off.** Neither consumer requires it — OpenTofu
never queries bucket versioning and behaves identically without it, and RKE2
manages its own snapshot retention. Meanwhile versioned buckets are where
SeaweedFS's known problems cluster: a 4.30/4.31 regression that lost data
during a mirror, and a conditional-write correctness hole that appeared
specifically with versioning plus object locking enabled. The state file's
recovery path is a filesystem snapshot of the data directory instead — same
protection, fewer moving parts, and it covers the etcd snapshots too.

## Verification

Measured 14 September 2026 against SeaweedFS 4.46. The same `put-object`
issued twice with `--if-none-match '*'`:

```
put #1   ETag "d41d8cd98f00b204e9800998ecf8427e"
put #2   PreconditionFailed — At least one of the pre-conditions
         you specified did not hold
```

412 on the second call. `use_lockfile = true` is safe. The ETag is the MD5 of
the empty string, confirming the zero-byte body round-tripped rather than
being mangled.

Two notes for anyone repeating this. Use a real empty file
(`printf '' > /tmp/probe`), not `/dev/null` — aws-cli v2 validates blob
arguments with `os.path.isfile()`, which rejects character devices
client-side before a request is sent. And run it with the *scoped* key, not
an admin one, since the scoped key is what OpenTofu will hold.

## Consequences

- Endpoint becomes `http://nas.rookery.internal:8333`; the `mc` workflow is
  replaced by `aws-cli`, with credentials declared in `s3.json`
- Two scoped identities, one per bucket, so a leaked snapshot credential
  cannot reach the state file
- OpenTofu must connect **directly** — SeaweedFS validates SigV4 using the
  `Host` header and mishandles the port once a proxy rewrites it, with
  reported failures specifically against the Terraform/OpenTofu S3 backend
- RKE2 needs `etcd-s3-bucket-lookup-type: path`; the `auto` default has a
  documented silent-failure mode against self-hosted endpoints — no error, no
  logs, zero uploads
- Backup of the state file moves from bucket versioning to a filesystem
  snapshot of `/volume2/docker/seaweedfs/data`

## Open

Ceph RGW's conditional-write support could not be confirmed — it is not in
the Tentacle v20.2.x release notes, and the `ceph/s3-tests` issue requesting
conditional-write coverage does not establish server-side support. If Ceph is
revisited, test rather than assume.

## References

- [SeaweedFS conditional-write PR #7154](https://github.com/seaweedfs/seaweedfs/pull/7154)
- [SeaweedFS versioning regression #9807](https://github.com/seaweedfs/seaweedfs/issues/9807)
- [Garage known issues — conditional writes](https://garagehq.deuxfleurs.fr/documentation/reference-manual/known-issues/)
- [OpenTofu S3 locking RFC](https://github.com/opentofu/opentofu/blob/main/rfc/20250211-s3-locking-with-conditional-writes.md)
- [OpenTofu s3 backend docs](https://opentofu.org/docs/language/settings/backends/s3/)
- [RustFS single-node install requirements](https://docs.rustfs.com/installation/linux/single-node-single-disk)
- [RKE2 backup and restore](https://docs.rke2.io/datastore/backup_restore)
- [LWN — A look at MinIO alternatives: Ceph and Garage](https://lwn.net/Articles/1077739/)
