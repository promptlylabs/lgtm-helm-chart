---
id: ADR-0006
type: adr
title: Track latest upstream chart versions, with every bump reviewed
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
    - ./0004-single-binary-minimal-footprint.md
    - ./0008-automated-dependency-updates-renovate.md
---

# ADR-0006 — Track latest upstream chart versions, with every bump reviewed

## Context

The reference implementation pins kube-prometheus-stack 82.x, loki 6.x, tempo 1.x and pyroscope 1.x — all several majors behind by mid-2026, partly because three charts changed homes: grafana and tempo moved to `grafana-community.github.io/helm-charts` around January 2026, loki followed in March (forked at 6.55.0) and then shipped ~11 major versions in three months under strict semver. Pyroscope did **not** migrate and still lives at `grafana.github.io/helm-charts`. Starting a long-lived shared chart several majors behind would bake in immediate upgrade debt.

## Decision

The first release pins the latest upstream versions (kube-prometheus-stack 86.2.2, grafana 12.4.4, loki 17.3.2, tempo 2.2.2, pyroscope 2.0.3, opentelemetry-operator 0.115.0), with the reference values adapted to those majors. Going forward, dependency bumps are exact-version pins arriving as pull requests; ADR-0008 narrows the original review-everything clause — non-major bumps automerge behind CI gates, while majors (with loki explicitly flagged as high-churn) remain human-reviewed. Repository URLs are verified per chart on every bump (never "normalised" across the grafana/grafana-community split).

## Alternatives considered

- **Pin the reference-proven versions and upgrade later.** Lowest initial risk (the values payload was production-validated against them), but ships a brand-new chart 4–11 majors behind, on partly frozen/deprecated chart lines, and defers the migration work to the worst possible time — after clients depend on it.
- **Auto-bump via Renovate with auto-merge.** Loki's major-version velocity makes unattended bumps reckless; a bad bump ships to every client at once.

## Consequences

- The adaptation work (loki 6.x→17.x, pyroscope 1.x→2.x value layouts) lands now, validated by `helm template`/kubeconform in CI and a kind smoke test, instead of accruing as debt.
- Pyroscope 2.x means the v2 storage architecture for all fresh installs — fine for new clusters, but migrating an existing v1 Pyroscope into this chart needs its own plan.
- Each bump PR reads upstream release notes; the chart's own minor version communicates stack changes to clients.

## Confidence

Medium-high. "Latest" is riskier than "proven" until the first kind smoke test and first client deployment validate the adapted values; the review-every-bump policy is the control for that risk.
