---
id: ADR-0003
type: adr
title: Deploy Grafana from the standalone chart with sidecar/ConfigMap provisioning
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
    - ./0005-otlp-push-scrapeless-prometheus.md
---

# ADR-0003 — Deploy Grafana from the standalone chart with sidecar/ConfigMap provisioning

## Context

Grafana can reach the cluster three ways: bundled inside kube-prometheus-stack (the reference pattern), as a standalone chart dependency, or managed by grafana-operator with Grafana/GrafanaDashboard/GrafanaDatasource CRs. Since the January 2026 chart migrations, kube-prometheus-stack pulls its bundled Grafana from the same `grafana-community` chart that is published standalone — bundling no longer means a different artifact, only different coupling. Programmatic dashboard management matters to us: projects ship their own dashboards alongside their workloads.

## Decision

We will declare the `grafana` chart (grafana-community) as a direct dependency of the umbrella with `kube-prometheus-stack.grafana.enabled: false`, and provision everything through the sidecars: dashboards from ConfigMaps labelled `grafana_dashboard: "1"`, datasources from ConfigMaps labelled `grafana_datasource: "1"`, alert rules from `grafana_alert: "1"` — discovered across all namespaces.

## Alternatives considered

- **Bundled in kube-prometheus-stack.** Zero-migration from the reference setup, but couples Grafana upgrades to kps releases and buries all Grafana config under `kube-prometheus-stack.grafana.*`. Its conveniences (auto-wired datasource, default dashboards) are all disabled in our opinionated setup anyway, so the coupling buys nothing.
- **grafana-operator.** Typed CRs with status/validation, first-class folders and alerting CRs, and the unique ability to manage external/Grafana Cloud instances. Rejected for now: a second operator on every client cluster, a second CRD-ordering problem on first install, and every consuming project would have to wrap its dashboard ConfigMaps in CRs. The operator can adopt an existing Grafana later, so this door stays open.

## Consequences

- Grafana versioning is decoupled from kube-prometheus-stack; values live at the top-level `grafana.*` key.
- The ConfigMap contract stays the org-wide way to ship dashboards: anything that can create a labelled ConfigMap can add a dashboard, with no dependency on this chart.
- No validation/status for dashboards — a malformed JSON surfaces only in sidecar logs. Accepted trade-off at current scale.
- The umbrella owns datasource provisioning (kps no longer auto-wires Prometheus); the chart ships a datasources ConfigMap with the full correlation config.

## Confidence

High on standalone-vs-bundled (same chart, strictly less coupling). Medium on sidecar-vs-operator long term: if multi-instance Grafana, Grafana Cloud, or dashboard validation become requirements, revisit grafana-operator — migration is additive, not a rewrite.
