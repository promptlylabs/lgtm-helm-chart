---
id: ADR-0005
type: adr
title: OTLP-push telemetry with a scrape-less, storage-only Prometheus
status: accepted
created: 2026-06-12
updated: 2026-07-02
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
---

# ADR-0005 — OTLP-push telemetry with a scrape-less, storage-only Prometheus

## Context

The classic kube-prometheus-stack model has Prometheus scrape everything (node-exporter, kube-state-metrics, application ServiceMonitors). The reference platform replaced that with an OpenTelemetry-native flow that proved out well: collectors own all collection and push OTLP; Prometheus is storage and query only. This ADR records that architecture centrally, since this chart bakes it in for every client.

## Decision

We keep the reference telemetry architecture as the chart's defaults:

- Three collector CRs: a **node collector** (DaemonSet: OTLP ingest, hostmetrics, kubeletstats, filelog, plus per-node scraping of unlabelled ServiceMonitors via target allocator), a **cluster collector** (single-replica StatefulSet: k8s_cluster, k8s_events, and ServiceMonitors labelled `opentelemetry.io/scope: cluster`), and an optional **Faro collector** (browser telemetry).
- Prometheus runs with `enableOTLPReceiver`, `translationStrategy: NoTranslation` (OTel metric names preserved 1:1), promoted k8s/service resource attributes, a 30m out-of-order window — and its own ServiceMonitor/PodMonitor selectors pinned to a never-matching label, so it scrapes nothing.
- node-exporter and kube-state-metrics are disabled; hostmetrics and k8s_cluster receivers replace them. Alertmanager is disabled; alerting is Grafana-managed.
- The shipped dashboards are OTel-native (they query `system.*`, `k8s.*`, `container.*` names) and depend on this flow.

## Alternatives considered

- **Classic scrape model.** Battle-tested and compatible with the wider dashboard ecosystem, but duplicates collection (collectors *and* exporters), and the org's dashboards/correlations are already OTel-native — switching back would orphan them.
- **Hybrid (Prometheus scrapes infra, OTLP for apps).** Two collection paths to operate and two naming schemes in one TSDB; rejected in the reference implementation for good reason.

## Consequences

- One pipeline for metrics, logs and traces, with consistent resource attributes — which is what makes the Grafana trace/log/metric correlations work.
- The community dashboard ecosystem (kube-prometheus mixins) does not work against OTel metric names; we maintain our own dashboards (shipped with this chart).
- PromQL queries must quote dotted metric names (`{"system.cpu.utilization"}`).
- Application ServiceMonitors keep working with zero labels — the node collector's target allocator picks them up automatically.

## Confidence

High — this is a transcription of a production-validated setup, not a new design. The main external risk is Prometheus changing its experimental OTLP/NoTranslation surface; pin bumps go through review (ADR-0006).

## Addendum (2026-06-30, updated 2026-07-02) — the `opentelemetry.io/scope` label and meta-monitoring

ServiceMonitors/PodMonitors carry an `opentelemetry.io/scope` label that decides which collector
scrapes them — a three-way convention:

- **unlabelled** → the **node collector** scrapes it (application workloads).
- **`scope: cluster`** → the **cluster collector** scrapes it (control-plane: apiserver, CoreDNS).
- **`scope: observability`** → the observability stack's own monitors (Grafana, Prometheus, the
  Prometheus operator, Loki, Tempo, Pyroscope). Whether the in-cluster collectors scrape these is
  controlled by `lgtm.metaMonitoring.enabled` (see below).

All bundled observability components therefore carry `scope: observability` on their
ServiceMonitors. Chart 0.1.6 fixed two stragglers that broke this invariant: Tempo was unlabelled
(so the node collector was self-scraping it), and Loki's ServiceMonitor was configured under the
wrong key — a top-level `serviceMonitor` instead of the chart's `monitoring.serviceMonitor` — so
it was never created at all.

### `lgtm.metaMonitoring.enabled` (added 2026-07-02)

The `scope: observability` label always identifies the stack's own monitors, but whether the
in-cluster collectors scrape them is a deployment choice — most installs, especially small
single-cluster ones, never run a separate meta stack, and reserving those targets for a stack that
doesn't exist means the observability components' own `/metrics` go uncollected. So the node
collector's target-allocator selector is keyed on `lgtm.metaMonitoring.enabled`:

- **`false` (default)** → `opentelemetry.io/scope NotIn [cluster]`. `NotIn` also matches monitors
  that lack the label, so the node collector picks up application **and** `scope: observability`
  targets — the stack self-monitors — while `scope: cluster` still routes to the cluster collector.
- **`true`** → `opentelemetry.io/scope DoesNotExist`. The node collector scrapes only unlabelled
  application monitors; `scope: observability` targets are reserved for a **separate
  meta-monitoring stack** (not deployed by this chart), which would select `scope: observability`
  to scrape exactly the observability components (and which the observability stack can itself
  scrape in turn — a meta stack carries no such label).

Because the label is applied either way, moving between the two modes is just this flag — no
re-labelling. This changed the default from the original addendum, where `scope: observability`
was scraped by neither in-cluster collector.
