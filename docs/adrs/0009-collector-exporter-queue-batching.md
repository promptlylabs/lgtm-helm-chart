---
id: ADR-0009
type: adr
title: Exporter-queue batching over the batch processor; OTAP/Arrow deferred
status: accepted
created: 2026-06-29
updated: 2026-06-29
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
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0006-latest-upstream-versions-reviewed-bumps.md
---

# ADR-0009 — Exporter-queue batching over the batch processor; OTAP/Arrow deferred

## Context

A mid-2026 review of recent OpenTelemetry changes against this chart raised two
questions:

1. The collector pipelines (node, cluster, faro) batched with the `batch`
   processor. Upstream is retiring it: it acknowledges data *before* the
   exporter confirms delivery and swallows per-batch errors, which breaks
   backpressure and yields at-most-once semantics. The supported replacement is
   batching inside each exporter's sending queue (`sending_queue.batch`), stable
   since collector ~v0.130. No version bump was needed: the pinned
   `opentelemetry-operator` Helm chart `0.115.0` has `appVersion: 0.153.0` and
   defaults `manager.collectorImage` to `opentelemetry-collector-k8s:0.153.0`, so
   the collectors already run v0.153.0 (the chart version `0.115.0` ≠ the
   operator/collector version `0.153.0` — the operator Helm chart versions
   independently of the operator binary).

2. Whether to adopt the OpenTelemetry Protocol with Apache Arrow (OTAP), which
   shipped a Phase 2 announcement in June 2026.

## Decision

1. **Replace the `batch` processor with per-exporter `sending_queue.batch`.** On
   every real exporter across all three collectors, batch in the sending queue
   (`sizer: items`, `min_size: 1024`, `flush_timeout: 10s` — mirroring the old
   `send_batch_size` / `timeout`) plus the queue's default `retry_on_failure`.
   The shared block lives in the `lgtm.collector.sendingQueue` helper.
   `memory_limiter` stays first in every pipeline; the `debug` exporter is left
   unqueued.

2. **Do not adopt OTAP/Arrow.** The topology is single-cluster with in-cluster
   backends: apps push to their own node's collector (`internalTrafficPolicy:
   Local`) and collectors export OTLP to in-cluster single-binary
   Loki/Tempo/Prometheus, which ingest OTLP, not OTAP. OTAP's only material
   benefit — wire-bandwidth reduction on collector→collector hops over
   WAN/cross-region/egress-metered links — does not apply here. OTAP components
   are also contrib-only (the chart runs the lighter k8s distro). Phase 1 is
   Beta; Phase 2 (Arrow as the in-pipeline representation, Rust engine) is
   explicitly experimental.

## Alternatives considered

- **Keep the `batch` processor.** Works today, but it is deprecated and on a
  removal path, and its early-ack / error-swallowing behaviour is precisely what
  the queue batcher fixes.
- **Disk-backed (persistent) exporter queue via the `file_storage` extension.**
  Better delivery durability across restarts, but needs a PVC per collector and
  the extension isn't in the k8s distro — disproportionate for this in-cluster,
  low-latency tier.
- **Adopt OTAP/Arrow now.** No bandwidth win in this topology, forces the
  heavier contrib image, and rides Beta/experimental surfaces.

## Consequences

- One fewer processor per pipeline; batching now shares the exporter queue's
  backpressure and retry, so a brief backend blip is retried rather than dropped
  mid-pipeline.
- Batching tunables are centralized in one helper — change once, applies to all
  collectors.
- The OTAP question is settled and recorded; revisit only if a
  gateway/aggregation tier or multi-cluster→central-backend shipping is ever
  added (the canonical OTAP use case).
- Watch-list, no action: **OTel Profiles** (public Alpha, Mar 2026) — the chart
  already ships Grafana Pyroscope; **GenAI semantic conventions** (client spans
  stabilized) — an app-instrumentation concern, passed through untouched by the
  collectors.

## Confidence

High for the batching change — a like-for-like swap onto the supported
mechanism, validated by the kind smoke test (the collector must accept the
rendered config). High for deferring OTAP, given the confirmed single-cluster,
in-cluster-backend topology.
