---
id: ADR-0007
type: adr
title: Assemble values.yaml from per-component fragments
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

# ADR-0007 — Assemble values.yaml from per-component fragments

## Context

An umbrella chart's opinionated defaults for six sub-charts plus its own keys produce a values.yaml many hundreds of lines long. Helm offers no include mechanism for chart default values: sub-chart defaults must be literal in the parent's single values.yaml. We want the maintenance experience of one file per component without changing what consumers see.

## Decision

The source of truth is `charts/lgtm/values.d/*.yaml` — one fragment per component (`00-lgtm`, `10-collectors`, `20-kube-prometheus-stack`, `30-grafana`, `40-loki`, `50-tempo`, `60-pyroscope`, `70-opentelemetry-operator`). `make values` (scripts/assemble_values.py) concatenates them in filename order into the committed `values.yaml` with a DO-NOT-EDIT header, failing if two fragments declare the same top-level key. CI (`make check-values`) fails any PR where the generated file is stale. `values.d/` is excluded from the packaged chart via `.helmignore`.

## Alternatives considered

- **One big hand-maintained values.yaml with section banners.** kube-prometheus-stack itself ships ~5,000 lines this way, so it's viable — but merge conflicts and review noise concentrate in one file, and nothing stops a kps edit from accidentally touching the loki block.
- **Local wrapper sub-charts, each carrying its own values.yaml.** True modularity (each wrapper could also own its templates), but every consumer override gains a nesting level — `loki.loki.loki.auth_enabled` from the umbrella — permanently uglier for every client repo, to save ourselves a build step.

## Consequences

- Flat override paths for consumers, identical to the reference implementation's; per-component files for maintainers.
- Contributors must run `make values` after editing fragments (pre-commit hook and CI both enforce it); "edit values.yaml directly" is a trap the header comment and CI guard against.
- ArtifactHub and `helm show values` render the assembled file, which is what users actually consume.

## Confidence

High. The mechanism is ~70 lines of stdlib Python with a deterministic output and two independent guards (pre-commit, CI). If it ever grates, collapsing back to a single file is a one-commit change.
