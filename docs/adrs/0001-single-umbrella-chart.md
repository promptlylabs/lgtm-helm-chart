---
id: ADR-0001
type: adr
title: Ship the observability stack as a single umbrella Helm chart
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
    - ./0002-single-observability-namespace.md
    - ./0007-values-assembled-from-fragments.md
---

# ADR-0001 — Ship the observability stack as a single umbrella Helm chart

## Context

We repeat the same observability stack (kube-prometheus-stack, Loki, Tempo, Pyroscope, Grafana, OpenTelemetry Operator + collectors, dashboards) across one infra repo per client. Each repo re-declares the same wrapper charts and values, and improvements made for one client never reach the others. The reference implementation lives in an internal platform repo as five per-component wrapper charts deployed by ArgoCD ApplicationSets.

## Decision

We will publish one umbrella chart, `lgtm`, from `promptlylabs/lgtm-helm-chart`, declaring all six upstream charts as dependencies and carrying the shared assets (OpenTelemetryCollector CRs, Grafana dashboards and datasources) as native templates. Client repos deploy the whole stack with a single `helm install` / one ArgoCD Application, overriding only client-specific values.

## Alternatives considered

- **Per-component wrapper charts (the reference model), published individually.** Keeps per-namespace isolation and small blast radius per sync, but every client still wires five Applications and their cross-component endpoints by hand — exactly the duplication this repo exists to remove.
- **Kustomize base / ArgoCD app-of-apps templates.** Would centralise the manifests but not the values contract, and gives up ArtifactHub distribution, versioning, and `helm upgrade` semantics.

## Consequences

- One version number moves the whole stack; component upgrades are released together (acceptable: the stack is designed and tested as a unit).
- All components land in one release and (by ADR-0002) one namespace.
- First-install ordering needs care: OpenTelemetryCollector CRs cannot be admitted until the operator webhook is ready. Mitigated by the `collectors.enabled` master switch (two-phase plain-Helm install) and documented ArgoCD `ServerSideApply=true` + retry settings.
- Clusters that already run prometheus-operator or the OTel operator need the documented adoption path (`<dep>.enabled=false` / CRD flags) to avoid CRD ownership conflicts.

## Confidence

High. The deprecated `lgtm-distributed` chart proved the umbrella shape for this exact stack; our addition (operator + CRs in the same release) is the only novel risk and is mitigated by a tested two-phase install.
