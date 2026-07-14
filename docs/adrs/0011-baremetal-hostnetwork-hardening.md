---
id: ADR-0011
type: adr
title: Bare-metal / hostNetwork hardening for the collectors
status: accepted
created: 2026-07-14
updated: 2026-07-14
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring]
related:
  implements: []
  informed_by:
    - ./0005-otlp-push-scrapeless-prometheus.md
  supersedes: []
  superseded_by: []
  see_also:
    - ./0004-single-binary-minimal-footprint.md
    - ./0009-collector-exporter-queue-batching.md
---

# ADR-0011 — Bare-metal / hostNetwork hardening for the collectors

## Context

The node collector is a `hostNetwork: true` DaemonSet (ADR-0005). That is correct for accurate host metrics, but on bare-metal, multi-NIC, on-prem clusters (RKE2 and similar) it exposes two failure modes that never surface on cloud or single-NIC nodes:

- **No node network metrics on multi-NIC nodes.** When a node has several NICs and no default interface, the kubelet reports an empty network name and the `kubeletstats` receiver emits **no** `k8s.node.network.io` at all (contrib #40915). The shipped OTel Network dashboard then has empty node-throughput panels.
- **Internal-telemetry port clash.** Sharing the host network means the collector's own internal-telemetry metrics endpoint binds a host port. On distros where `:8888` is already in use the collector crashes on startup with `bind: address already in use`.

A third, related concern on these deployments is durability: on-prem clusters often have a less reliable link to storage backends, and a collector restart during a backend-down window drops the in-memory sending queue (ADR-0009).

All three need addressing without changing the defaults for existing (cloud/single-NIC) installs, and without pinning a bespoke collector image — the shipped `opentelemetry-collector-k8s` distribution (operator chart 0.118.0 → appVersion 0.153.0) already carries the needed surface (`collect_all_network_interfaces`, `service.telemetry.metrics.readers`, and the `filestorage` extension).

## Decision

Add two value-gated knobs on the node collector, both **off by default**:

- **`collectors.node.collectAllNetworkInterfaces`** — when `true`, sets `collect_all_network_interfaces: { node: true }` on the `kubeletstats` receiver (the opt-in fix from contrib #38737, available since collector 0.131). Scoped to `node` only so cardinality stays bounded to one series per node NIC; it adds an `interface` resource attribute. The OTel Network dashboard aggregates node network metrics with `sum`, so it renders unchanged.
- **`collectors.node.internalMetricsPort`** (default `8888`) — renders the collector's `service.telemetry.metrics.readers` with a `pull`/`prometheus` reader bound to `0.0.0.0:<port>`. The legacy `service.telemetry.metrics.address` shortcut was removed in collector v0.111+, so a `readers` block is the supported way to set this. Keeping the default at `8888` preserves current behavior.

And one opt-in durability knob (default off) on **both** collectors, extending the sending-queue design of ADR-0009:

- **`collectors.persistentQueue.enabled`** — when `true`, backs each exporter's `sending_queue` with a `file_storage/queue` extension on durable storage (node DaemonSet → hostPath, cluster StatefulSet → `volumeClaimTemplates` PVC), so queued batches survive a collector restart. Because the collector image is distroless and runs as UID 10001, a small `chown` initContainer (`collectors.persistentQueue.initImage`) makes the queue directory writable before the collector starts.

The `values-baremetal.yaml` example overlay turns all three on (and is exercised by the lint job's `helm template` run), and a lint assertion checks the enabled path renders the config while the default path does not.

## Alternatives considered

- **Always collect all interfaces / hardcode a non-8888 port.** Rejected: it would change cardinality and the internal-metrics endpoint for every existing install; ADR-0005's defaults are meant to stay stable.
- **Also exclude the target-allocator `ta-container` from filelog** (proposed alongside this work). Rejected: the existing `otc-container` filelog exclude exists to break a genuine feedback loop — the collector forwards logs and emits its own log lines, which filelog re-reads and re-forwards. The target allocator does not forward logs, so its reconcile logs cannot amplify; they are also useful for debugging target assignment and are kept.
- **Wire a chart-managed self-scrape to follow `internalMetricsPort`.** Deferred: the chart does not enable `spec.observability.metrics` and ships no ServiceMonitor/PodMonitor for the internal endpoint, so there is nothing to keep in sync today. The README documents that any self-scrape added later must target the configured port.

## Consequences

- Multi-NIC bare-metal nodes report per-interface node network metrics once opted in; the network dashboard fills in without edits.
- Operators on conflicting hosts can relocate the internal-telemetry port instead of patching the CR by hand.
- The internal-telemetry endpoint binds `0.0.0.0:<port>` explicitly. Nothing in the chart scrapes it by default; a user-added scrape (or the operator self-monitor, which targets `8888`) must be pointed at the configured port — documented in the chart README.
- With `persistentQueue` on, each collector gains a durable volume, a `file_storage/queue` extension and a root `chown` initContainer; the DaemonSet writes one queue dir per node (hostPath), the StatefulSet a per-replica PVC. Enqueue/dequeue now hits disk, and the queue directory must be sized for the worst-case backend-down window.
- Defaults are unchanged, so existing installs render byte-for-byte the same except for the explicit (default-`8888`) `readers` block.

## Confidence

High — the network/port knobs are thin, opt-in passthroughs to well-established collector config on the already-shipped image, and the durable queue reuses the `filestorage` extension already in the `otelcol-k8s` distribution. All three are guarded by the values schema and a render assertion. The main residual risk is upstream renaming the `readers` / `collect_all_network_interfaces` / `file_storage` surface, which pin bumps review (ADR-0006).
