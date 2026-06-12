---
id: ADR-0004
type: adr
title: Default every component to single-binary mode with minimal footprint
status: accepted
created: 2026-06-12
updated: 2026-06-12
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
    - ./0001-single-umbrella-chart.md
    - ./0006-latest-upstream-versions-reviewed-bumps.md
---

# ADR-0004 — Default every component to single-binary mode with minimal footprint

## Context

The stack runs on every client cluster, most of them small single-cluster deployments where the observability bill must stay far below the workloads being observed. Upstream charts default to scale-out shapes: Loki's chart enables an nginx gateway plus two memcached caches (the chunks cache alone requests 8 GiB), Pyroscope ships Alloy by default, and kube-prometheus-stack brings Alertmanager, node-exporter and kube-state-metrics.

## Decision

Every component defaults to its single-binary/monolithic mode, one replica, no HA, PVC-backed local storage: Loki `deploymentMode: Monolithic` with the gateway, chunks cache and results cache disabled (endpoints go straight to `loki:3100`, which natively serves both queries and OTLP ingest); Tempo via the single-binary chart; Pyroscope single binary with Alloy and MinIO off; Prometheus one replica; Grafana one replica; Alertmanager, node-exporter and kube-state-metrics disabled (ADR-0005 covers their OTel replacements). Scaling out is always a values override, never a default.

## Alternatives considered

- **Keep upstream defaults (gateway, caches, HA replicas).** Resilient and faster at scale, but triples the pod count and adds gigabytes of memory reservations that small clusters cannot justify.
- **Distributed charts (`loki-distributed`/`tempo-distributed`, Mimir).** What the deprecated `lgtm-distributed` used; built for scales none of our clients are at.

## Consequences

- The lowest possible idle cost: roughly one pod per signal type plus the collectors.
- Single replica means brief telemetry gaps during pod restarts and node drains; acceptable for internal observability, and OTLP retry buffers smooth most of it.
- No Loki gateway means anything that previously pointed at `loki-gateway:80` must use `loki:3100`; query performance at larger volumes may eventually want the results cache re-enabled (a values override away).
- Filesystem storage limits Loki to exactly one replica (chart-enforced); moving to object storage (see the Azure example values) is the path to scaling.

## Confidence

High for current cluster sizes. The signals that would make us reconsider: Loki query latency complaints (re-enable caches), ingestion above what one binary handles (move to SimpleScalable + object storage), or an SLO on observability availability (replicas + HA).
