---
id: ADR-0012
type: adr
title: First-party, component-gated self-observability dashboards
status: accepted
created: 2026-07-14
updated: 2026-07-14
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
    - ./0003-standalone-grafana-with-sidecar-provisioning.md
    - ./0004-single-binary-minimal-footprint.md
    - ./0005-otlp-push-scrapeless-prometheus.md
---

# ADR-0012 — First-party, component-gated self-observability dashboards

## Context

The chart shipped OTel-native **infrastructure** dashboards (hosts, cluster, namespace, container,
storage, network, Karpenter/NAP) plus one component dashboard, `loki-operational`. Operators had no
first-party way to watch the stack's **own** components — Prometheus TSDB/OTLP ingest, Loki
ingestion/compaction/queries, the OTel collectors' receiver/exporter/queue health, Grafana, Tempo
and Pyroscope. `loki-operational` was also partly broken: it hard-coded `namespace="loki"`, which
does not match a release-namespace install, so its Kubernetes-resource panels rendered empty.

The obvious shortcut — reference upstream community dashboards so they track their source — does not
work here. This stack is deliberately non-standard (ADR-0004, ADR-0005): Prometheus is
scrape-less and ingests OTLP with `translationStrategy: NoTranslation` (dotted metric names), and
Loki runs in **monolithic** single-binary mode (one `loki` target, not distributor/ingester/querier
microservices). Upstream dashboards assume scraped metrics with vanilla label sets and, for Loki, a
microservices topology; against this stack their panels are empty or wrong — the exact failure mode
`loki-operational` already showed.

## Decision

Ship **first-party JSON dashboards** for the stack's own components, authored against this stack's
real metric names (validated on a live kind stack) and consistent with the existing OTel-native set.

- New dashboards under `charts/lgtm/dashboards/`: `prometheus`, `loki` (replacing
  `loki-operational`, rewritten for monolithic mode), `otel-collector`, `grafana`, `tempo`,
  `pyroscope`. They query the **`prometheus`** datasource — component self-metrics
  (`loki_*`, `prometheus_*`, `otelcol_*`, `grafana_*`, …) live in Prometheus, scraped from the
  `scope: observability` ServiceMonitors and pushed via OTLP (ADR-0005). Self-metrics are scoped by
  `job`/`pod`/`instance`, **not** by namespace, since the metrics pipeline does not apply the full
  `k8s.*` resource enrichment.
- **Per-component gating.** `templates/grafana/dashboards.yaml` maps each dashboard basename to the
  component it observes and only provisions it when that component is enabled — there is no value in
  a Loki dashboard on a release without Loki. The `otel-*` infrastructure dashboards follow
  `collectors.enabled`; `home` is always provisioned. This reuses existing component flags, so no
  new values keys and no `values.schema.json` change.
- **No recording rules.** Latency-quantile panels compute `histogram_quantile()` at query time over
  raw `*_request_duration_seconds_bucket` series (as the old `loki-operational` already did). We do
  **not** ship the loki-mixin recording rules or any `PrometheusRule`, so there is no rule-plumbing
  or meta-monitoring rule surface to maintain.
- **Collect the collectors' own telemetry.** The OTel Collector dashboard needs `otelcol_*` metrics,
  which the operator exposes on each collector's `:8888` monitoring Service but which nothing
  scraped. We add a `ServiceMonitor` (`templates/collectors/servicemonitor.yaml`, gated on
  `collectors.enabled`) selecting those monitoring Services and labelled
  `opentelemetry.io/scope: observability` — extending the ADR-0005 self-monitoring convention to the
  collectors themselves. With `metaMonitoring.enabled=false` (default) the node collector's target
  allocator scrapes it and pushes `otelcol_*` to Prometheus; with it enabled the metrics are reserved
  for the external meta stack, exactly like every other component. For the two collectors to be
  distinguishable in the dashboard, each carries a distinct `service.telemetry.resource.service.name`
  (`otel-node-collector` / `otel-cluster-collector`) — the distribution default is a shared
  `otelcol-k8s`, which collapses their self-metrics into one series. That name is what Prometheus
  rebuilds `job` from on OTLP ingest, so `job` is how the dashboards and rules select a collector;
  `service` is the operator-derived Kubernetes Service name (`…-collector-monitoring`) and is not
  the collector's identity. Every collector CR must also set `without_units: false` /
  `without_type_suffix: false` on its telemetry reader: the reader the operator injects when the
  block is left implicit omits both, and the SDK then strips the classic
  `_total`/`_seconds`/`_bytes` suffixes, landing that collector's `otelcol_*` metrics under a
  disjoint set of names from the ones the dashboards and rules query.

## Alternatives considered

- **Reference upstream dashboards at runtime (`gnetId`/`url` provisioning).** Grafana's init
  container can download a dashboard from grafana.com (pinned to a revision) at pod start. Rejected:
  it downloads JSON verbatim with no hook to rewrite the queries/labels for OTLP/NoTranslation names
  or monolithic Loki, so the panels are empty; it also adds a runtime egress dependency on
  grafana.com, against this chart's self-contained, offline-friendly design.
- **grafana-operator `GrafanaDashboard` CRD with a `url:`/`grafanaCom:` source + periodic resync.**
  Would keep referenced dashboards fresh, but the chart provisions Grafana via the Helm subchart +
  sidecar (ADR-0003), not the operator; adopting it is a large architectural change for the same
  topology-mismatch problem.
- **Vendor the upstream mixins as-is.** Same empty/wrong panels in monolithic + OTLP mode, plus
  their recording-rule dependency. ADR-0005 already rejected community mixins for this stack.
- **Ship loki-mixin recording rules as a value-gated `PrometheusRule`** to power quantile panels.
  Unnecessary — query-time `histogram_quantile` over the raw buckets is sufficient at this scale and
  avoids maintaining a rule set.

## Consequences

- Operators get out-of-the-box, correct dashboards for every enabled component; disabled components
  add nothing to Grafana.
- We own these JSON files and their metric names. The burden is low: component self-metric names
  (`loki_*`, `prometheus_*`, `otelcol_*`, …) are stable and slow-changing, unlike the infra metrics.
- **Dependency on `metaMonitoring.enabled=false` (the default).** The component self-metric
  dashboards only have data when the in-cluster collectors self-scrape the `scope: observability`
  targets. With `lgtm.metaMonitoring.enabled=true`, those targets are reserved for a separate meta
  stack (ADR-0005) and these dashboards sit empty in this Grafana. Gating stays on the component
  flag (not additionally on the meta-monitoring mode) to keep it legible; the caveat is documented
  in the chart README and the dashboards' descriptions.
- Object-store panels in the Loki dashboard (`loki_s3_*`) only populate on S3-backed installs; on
  the default filesystem backend (ADR-0004) they are intentionally empty.
- The smoke test's dashboard-count assertion tracks the shipped total and must be bumped when
  dashboards are added or removed.

## Confidence

High for the design and gating. Medium on exact metric/label names for the less-common surfaces
(Prometheus OTLP-receive counters, target-allocator scrape health, object-store metrics), which were
validated against a live kind stack where present and otherwise against upstream `/metrics` — the
runtime smoke test is the ongoing backstop.
