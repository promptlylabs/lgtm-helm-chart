---
id: ADR-0010
type: adr
title: Optional Thanos sidecar and query stack for long-term metrics
status: accepted
created: 2026-07-03
updated: 2026-07-03
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring]
related:
  implements: []
  informed_by: []
  supersedes: []
  superseded_by: []
  see_also:
    - ./0004-single-binary-minimal-footprint.md
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0006-latest-upstream-versions-reviewed-bumps.md
---

# ADR-0010 — Optional Thanos sidecar and query stack for long-term metrics

## Context

Prometheus in this chart is storage-only on a local PVC (ADR-0005): metrics are lost when the node is lost, and nothing can be queried past local retention. Loki and Tempo already ship to object storage in the cloud overlays, so metrics were the last signal without a durable, long-term option. Consumers asked specifically to both **survive node loss** and **query metrics beyond local retention** (a single-node K3s consumer keeps only 24h locally).

kube-prometheus-stack already bundles the Prometheus Operator, which supports a Thanos **sidecar** (`prometheusSpec.thanos`) that uploads completed 2h TSDB blocks to S3-compatible object storage and exposes a StoreAPI. But the sidecar alone is backup-only: querying the uploaded blocks needs Thanos **Query** (a Prometheus-API fan-out over the sidecar + a store), a **Store Gateway** (serves blocks from the bucket), and a **Compactor** (compacts/downsamples and enforces bucket retention — without it the bucket grows forever). Those three are not part of kube-prometheus-stack.

## Decision

Add optional Thanos support, **disabled by default**, in two halves that keep the default render byte-identical:

- **Sidecar** — configured via the `kube-prometheus-stack.prometheus.prometheusSpec.thanos` pass-through and `prometheus.thanosService` (gRPC 10901). Object storage is a Thanos `objstore.yml` in an **existing Secret** the consumer provides out of band (e.g. External Secrets Operator) — credentials are never templated into the chart, matching the Loki/Grafana ESO pattern. The operator auto-disables local compaction when object storage is set; we also set `disableCompaction: true` explicitly. Because Helm cannot compute sub-chart values from an umbrella toggle, the sidecar is delivered through the `examples/values-thanos.yaml` overlay, not a boolean.
- **Query / Store Gateway / Compactor** — **hand-rolled umbrella-owned templates** (`templates/thanos/`) gated by real `thanos.*` booleans, reusing the same objstore Secret. Grafana's Prometheus datasource auto-repoints to Thanos Query when the stack is enabled (the `prometheus` UID and all correlations are preserved). The Compactor is a singleton (Recreate, one replica).

The Thanos image is pinned (matching the operator's sidecar default) and Renovate-managed like every other dependency (ADR-0006/0008) via a custom manager that edits the values.d fragment, the generated `values.yaml`, and the overlay together.

## Alternatives considered

- **Sidecar only, document the rest as a follow-up.** Smaller, but leaves the actual requirement — querying the bucket — unmet; sidecar-only is backup, not queryability.
- **`thanos-community/thanos` sub-chart.** Actively maintained, upstream `quay.io/thanos` images, ESO-capable — but its own `Chart.yaml` depends on `kube-prometheus-stack 87.0.1` + `rustfs`, colliding with our pinned kube-prometheus-stack 86.3.2 and pulling an unwanted bundled object store; it is a standalone turnkey bundle (`kubeVersion: >=1.30`, low adoption), not an embeddable component library.
- **Bitnami Thanos sub-chart.** Ruled out by Bitnami's 2025 catalog deprecation (images moved to `bitnamilegacy`), which conflicts with ADR-0006's pin-and-review discipline.
- **An umbrella boolean that toggles the sidecar.** Impossible: Helm sub-chart values are static YAML, so an umbrella toggle cannot inject `prometheusSpec.thanos` into kube-prometheus-stack. The overlay is the idiomatic path (same as the cloud storage overlays).

## Consequences

- Metric blocks become durable in object storage and queryable beyond local retention, with no change for existing users (feature off by default; default `helm template` output unchanged).
- Local `retention` becomes a rolling cache in front of the bucket. It must stay ≥ a few hours; a too-tight `retentionSize` can evict a 2h block before the sidecar uploads it, gapping the archive — documented in the overlay and README.
- The chart now owns three plain workloads (its first non-collector Deployments/StatefulSet) and their upkeep, but avoids a heavyweight, uncertainly-maintained sub-chart dependency and the kube-prometheus-stack version collision.
- No live object-storage smoke test is added (it needs real credentials); CI render-asserts the enabled path. A MinIO-backed smoke test is a possible follow-up.

## Confidence

High on the sidecar and the values/Renovate wiring (verified against kube-prometheus-stack 86.3.2 / operator v0.91.0 and validated by lint/template/kubeconform). Medium on the hand-rolled query stack's runtime behaviour until a live object-storage deployment exercises Store Gateway/Compactor end to end.
