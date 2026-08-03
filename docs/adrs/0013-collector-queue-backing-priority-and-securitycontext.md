---
id: ADR-0013
type: adr
title: Collector queue backing, critical PriorityClasses and securityContext surface
status: accepted
created: 2026-08-03
updated: 2026-08-03
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring]
related:
  implements: []
  informed_by:
    - ./0011-baremetal-hostnetwork-hardening.md
    - ./0009-collector-exporter-queue-batching.md
    - ./0005-otlp-push-scrapeless-prometheus.md
  supersedes: []
  superseded_by: []
  see_also:
    - ./0004-single-binary-minimal-footprint.md
---

# ADR-0013 — Collector queue backing, critical PriorityClasses and securityContext surface

## Context

An incident on a production RKE2 cluster (Rocky Linux 10, SELinux **Enforcing**) surfaced three
independent defects in the collector configuration. Some nodes in that cluster had been manually
set to Permissive, which masked the SELinux ones until a node rebooted.

**1. The node collector's persistent queue was backed by `hostPath` (ADR-0011).** `fsGroup` is
applied by kubelet only to volume plugins that support ownership management — `emptyDir`,
`configMap`, `secret`, `projected`, `downwardAPI` and PVCs. `hostPath` is not one of them, and
that is the *only* reason ADR-0011 introduced the `queue-permissions` chown initContainer. On an
Enforcing node that initContainer cannot succeed: the directory inherits `container_var_lib_t`
from the `/var/lib` default, which `container_t` may not write.

```
chown: /var/lib/otelcol-queue: Permission denied
avc: denied { setattr } scontext=...:container_t tcontext=...:container_var_lib_t
```

It runs as root, so this is SELinux and not DAC. Result: `CrashLoopBackOff`, 1100+ restarts, no
telemetry from the node. The chown is not even the whole problem — had it succeeded, the
collector process itself would still have been denied write on that type. A secondary concern:
a hostPath queue grows outside any kubelet accounting or quota, and the same incident involved a
node whose small root partition filled up. (Note the fix below bounds that growth; it does not
generally move it to another filesystem — see the Decision.)

**2. `collectors.priorityClassName` defaulted to `""`.** The values comment justified this on the
grounds that PriorityClasses are cluster-specific. That holds for custom classes, but
`system-node-critical` and `system-cluster-critical` are built into every Kubernetes cluster, so
defaulting to one of them cannot break an install. It matters because kubelet's eviction
admission handler rejects non-critical pods while a node carries the `DiskPressure` condition,
and "critical" is defined precisely as carrying one of those two classes (priority ≥
`SystemCriticalPriority`). During the disk-pressure incident the node collectors were evicted
exactly when observability was most needed.

**3. No `securityContext` or `podSecurityContext` was exposed on any collector.** Beyond `fsGroup`
for (1), this blocked `seLinuxOptions`, which the node collector needs in order to read
`/var/log/pods` for container logs:

```
avc: denied { read } comm="otelcol-k8s" name="pods"
  scontext=...:container_t tcontext=...:container_log_t tclass=dir
```

Relabelling `/var/log/pods` is not an option — kubelet and containerd expect `container_log_t`
there — so the collector must run in a domain permitted to read it.

## Decision

**Make the node queue backing configurable and default it to `emptyDir`**
(`collectors.persistentQueue.node.backend`, `emptyDir` | `hostPath`). With `emptyDir`,
`fsGroup: 10001` on the pod security context makes kubelet set ownership and the container
runtime labels the volume with the pod's own SELinux MCS category, so the chown initContainer is
dropped entirely and Enforcing nodes need no manual relabelling. An `emptyDir` also counts toward
the pod's ephemeral storage, so kubelet can account for and bound it (`sizeLimit`) rather than the
queue growing invisibly on the host — which matters given the disk-pressure half of the incident.
It is *not*, however, on a different filesystem in the general case: an `emptyDir` lives under the
kubelet root directory (`/var/lib/kubelet` by default), which on a stock node layout is the same
filesystem as a `/var/lib` hostPath. It only lands elsewhere where that directory is a separate
mount. `emptyDir` survives container restarts — the case ADR-0011's durable queue exists for — but
not pod recreation, so `hostPath` stays available as an opt-in for anyone who needs the queue to
outlive a pod. `collectors.persistentQueue.initImage` survives, used only on the `hostPath` path
and the cluster escape hatch below.

**Stop rendering the chown initContainer on the cluster collector by default.** `fsGroup` *does*
apply to PVCs, so `podSecurityContext.fsGroup: 10001` makes the `volumeClaimTemplates` queue
writable — but only where the CSI driver actually implements ownership management. File/NFS-backed
drivers (EFS, Azure Files, `nfs-subdir-provisioner`) declare `CSIDriver.fsGroupPolicy: None`, and
the default `ReadWriteOnceWithFSType` policy skips volumes with no `fsType`; on those the queue
directory would stay root-owned and the distroless collector could not write it. So the
initContainer is retained behind `collectors.persistentQueue.cluster.chownInitContainer`
(default `false`) rather than deleted. On block storage — the common case — the default install
pulls no busybox image at all.

**Default the collectors to the built-in critical classes** and expose them per collector:
`collectors.node.priorityClassName: system-node-critical` (a node-level agent, the same category
as the CNI and CSI DaemonSets), `collectors.cluster.priorityClassName: system-cluster-critical`
(a cluster-scoped singleton), `collectors.faro.priorityClassName: ""` (optional browser telemetry,
not infrastructural). The shared `collectors.priorityClassName` key is **removed** rather than
deprecated: the values schema is `additionalProperties: false`, so an upgrade that still sets it
fails loudly instead of silently ignoring the operator's intent.

**Expose `podSecurityContext` and `securityContext` on all three collectors**, passed through to
the `OpenTelemetryCollector` CR's pod- and container-level fields. `seLinuxOptions` is supported
on both. For SELinux-enforcing clusters the chart documents `type: spc_t` at pod level on the node
collector — the convention for log collectors on SELinux systems — and ships
`examples/values-selinux.yaml`.

**Fix an adjacent latent bug** found while making these changes: `lgtm.collector.sendingQueue` now
takes `(dict "root" . "storage" <bool>)`. With `persistentQueue.enabled=true` **and**
`faro.enabled=true`, the faro collector's exporters previously emitted `storage: file_storage/queue`
while the faro template defined no such extension, no volume and no `service.extensions` — the
collector would fail config validation at startup. No CI case rendered that combination; one now
exists.

## Alternatives considered

- **Keep `hostPath` as the default and document a relabelling step.** Rejected: it makes the
  documented default path require out-of-band host configuration on every node of an Enforcing
  cluster, to buy durability across pod recreation that the queue's stated use case (surviving a
  restart during a backend-down window) does not need.
- **A per-node PVC via generic ephemeral volumes.** Rejected: the PVC is deleted along with the
  pod, so it provides no durability over `emptyDir` while provisioning real storage on every node.
- **Auto-injecting `fsGroup` only when the queue is enabled.** Rejected in favour of an explicit,
  commented default in `values.d/10-collectors.yaml`; the values file is the chart's primary
  documentation surface and template-side magic is harder to discover. `fsGroup` also applies to
  the configMap/projected volumes the pod already mounts, which is harmless.
- **Keeping `collectors.priorityClassName` as a deprecated fallback.** Rejected: the chart is 0.x,
  and a strict schema turns removal into an immediate, actionable error rather than a silent
  behaviour change.
- **Defaulting faro to a critical class as well.** Rejected: browser telemetry is optional and
  off by default; claiming node-critical priority for it is not justifiable.

## Consequences

- Enabling `persistentQueue` no longer adds an initContainer or a busybox image pull on any
  default path, and works unchanged under SELinux Enforcing.
- The node queue is now visible to kubelet's ephemeral-storage accounting and bounded by
  `persistentQueue.node.sizeLimit` (default `2Gi`); exceeding an `emptyDir` `sizeLimit` causes
  kubelet to evict the pod, so it must be sized for the worst-case backend-down window. Note this
  bound is the benefit — the volume is not necessarily on a different filesystem from the old
  hostPath (see above), so "moves the queue off `/`" is only true where `/var/lib/kubelet` is a
  separate mount.
- Installs whose cluster-collector PVC is on file/NFS-backed storage must set
  `persistentQueue.cluster.chownInitContainer: true` on upgrade, or the collector cannot write
  its queue directory. Called out in the README's breaking-changes note.
- Choosing `backend: hostPath` keeps the old behaviour and its constraints — a root chown
  initContainer, plus `semanage fcontext` / `restorecon` (or `spc_t`) on Enforcing nodes.
- Collector pods are now admitted by kubelet on nodes under `DiskPressure`. They can also
  **preempt** lower-priority workloads on a full node, which is the intended trade for a node
  agent but is a behaviour change for existing installs.
- **The target-allocator Deployments stay non-critical**: `spec.targetAllocator` in the operator's
  `v1beta1` CRD exposes `securityContext`, `podSecurityContext`, `tolerations` and `nodeSelector`,
  but no `priorityClassName`. Nothing the chart can do; documented in the README.
- `spc_t` removes SELinux confinement for the node collector pod where it is applied. It is
  opt-in via an example overlay, scoped to the one collector that reads host paths.
- Upgrades from < 0.12.0 that set `collectors.priorityClassName` fail schema validation and must
  move to the per-collector key.
- **One change is silent rather than loud, and it is the broadest one.** Every install running
  `persistentQueue.enabled: true` migrates from hostPath to `emptyDir`, not just those that set
  `persistentQueue.node.hostPath` explicitly: that key has a working default
  (`/var/lib/otelcol-queue`), so hostPath is what every such install was already getting, and the
  chart's own `values-baremetal.yaml` overlay enables the queue without naming it. A schema cannot
  catch this — `hostPath` remains a legitimate key and `enabled: true` a legitimate value — so it
  is called out in the README's breaking-changes note. Setting `backend: hostPath` restores the
  previous behaviour. Two follow-on effects: batches still queued in the old directory at upgrade
  time are abandoned rather than drained, and `/var/lib/otelcol-queue` is orphaned on every node
  until an operator removes it — which is worth doing promptly on the very hosts whose small root
  partition motivated this ADR.

## Confidence

High. Every field used is verified against the `opentelemetry.io/v1beta1` CRD shipped with
opentelemetry-operator 0.120.0 (`spec.podSecurityContext`, `spec.securityContext`,
`spec.priorityClassName`, `spec.volumes[].emptyDir.sizeLimit`), and the `fsGroup`/`hostPath` and
DiskPressure-admission behaviours are long-standing, documented Kubernetes semantics rather than
version-sensitive details. Render assertions in the lint workflow cover both queue backings, the
default priority classes, the absence of the chown initContainer, and the faro regression. The
residual risk is a cluster-level `ResourceQuota` scoped to PriorityClass that refuses the
`system-*` classes in the observability namespace, which surfaces as a clear admission error and
is resolved by setting `priorityClassName: ""`.
