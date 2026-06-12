---
id: ADR-0002
type: adr
title: Deploy the whole stack into a single observability namespace
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
---

# ADR-0002 — Deploy the whole stack into a single observability namespace

## Context

The reference deployment gives each component its own namespace (`prometheus`, `loki`, `tempo`, `pyroscope`, `opentelemetry`) via separate ArgoCD Applications. With a single umbrella release (ADR-0001) we would like to keep that organisation, but Helm installs a release into one namespace and sub-charts can only relocate themselves if they implement `namespaceOverride`.

## Decision

We will deploy everything into the release namespace (suggested: `observability`). Cross-component endpoints are computed for the release namespace by chart helpers. For clients that require relocating a component, the sub-charts that support `namespaceOverride` (kube-prometheus-stack, grafana, loki, opentelemetry-operator) are documented as opt-in overrides, together with the endpoint overrides that must accompany them.

## Alternatives considered

- **Multi-namespace via `namespaceOverride` everywhere.** Not achievable: the tempo and pyroscope charts hardcode `.Release.Namespace` in every template, so 2 of 6 components can never move. A "namespace per component" promise would be 60% kept.
- **Templating `Namespace` objects in the umbrella.** Makes `helm uninstall` / ArgoCD prune delete the namespaces — and with them the Prometheus/Loki/Tempo data PVCs. Unacceptable failure mode for a chart meant to be operated casually.
- **Per-component ArgoCD Applications.** That is the per-component model ADR-0001 moves away from; namespace isolation is not worth reintroducing five Applications per client.

## Consequences

- Simpler cross-component DNS (short service names work), webhook certificates, and sidecar discovery.
- Resource quotas / RBAC cannot be scoped per component namespace; per-cluster operators who need that must fall back to component-level overrides.
- The hardcoded same-namespace endpoints that must live in sub-chart values (Tempo remote-write URL, Loki OTLP env var) stay correct by default.

## Confidence

High. This is what `lgtm-distributed` and comparable umbrella charts do; the blocking facts (missing `namespaceOverride` in tempo/pyroscope) were verified against the chart templates at the pinned versions.
