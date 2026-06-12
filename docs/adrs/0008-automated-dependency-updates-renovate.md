---
id: ADR-0008
type: adr
title: Automate dependency updates with Renovate, gated by a kind smoke test
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
    - ./0006-latest-upstream-versions-reviewed-bumps.md
---

# ADR-0008 — Automate dependency updates with Renovate, gated by a kind smoke test

## Context

The chart pins six fast-moving dependencies (loki alone shipped ~11 majors in three months). ADR-0006's "every bump is a reviewed PR" policy means hand-bumping versions every few days — exactly the toil this central chart exists to remove. At the same time, dependency updates can break things that `helm template` cannot see: a collector exporter rename renders fine and crash-loops at runtime, and major versions sometimes change values layouts entirely.

## Decision

We adopt **Renovate via the hosted Mend GitHub App** (scoped to this repository), configured in `renovate.json5`:

- **Version mapping** (the prometheus-community convention): dep patch → chart patch, dep minor → chart minor, dep **major → chart minor** plus mandatory human review. Chart **majors are reserved for breaking changes to this chart's own values contract** — the umbrella's semver describes *its* interface, not upstream internals. Renovate bumps `Chart.yaml` `version` in the same PR via `bumpVersions` templated on the update type.
- **Automerge**: non-major updates merge automatically once the required checks pass; majors carry the `major-upstream` label and wait for a reviewer, who adapts `values.d/` and the collector configs if needed and decides whether to escalate the chart bump to a major.
- **Gate**: a new required `smoke` check installs the full stack on a throwaway kind cluster on every PR (two-phase install, collectors Ready, then asserts a test span reaches Tempo, host metrics reach Prometheus, container logs reach Loki, and Grafana provisioned the datasources/dashboards). This is what makes automerge defensible — it catches runtime breaks, not just render breaks. `lint` (template permutations + kubeconform) remains required as well.
- **Cadence and supply-chain guard**: non-major updates arrive as one grouped PR per week (Monday); `minimumReleaseAge: 7 days` so we never consume a release younger than a week — compromised or broken releases are usually yanked within days.
- Releases stay fully automatic (merge → chart-releaser publishes, since the version was bumped in the PR). Clients pin `targetRevision`, so automation only keeps the shelf stocked; nothing reaches a cluster until a client bumps.
- The static `artifacthub.io/changes` annotation is dropped — it would go stale on automated releases, and automating it would need a bot token whose PR commits re-trigger CI (the complexity we avoided by choosing the hosted app). GitHub release notes are auto-generated instead.

## Alternatives considered

- **Dependabot.** Supports Helm now, but cannot bump the chart's own version, regenerate Chart.lock, or apply per-update-type rules — every PR would need a human follow-up commit, defeating the purpose.
- **Self-hosted Renovate (GitHub Action + PAT/App token).** Full control, but PRs opened with the default token don't trigger CI, so it needs a managed token — recurring secret maintenance for no benefit over the free hosted app.
- **Mirroring update types exactly (dep major → chart major).** Simple and was the initial idea, but loki's major-version velocity would inflate our major number within months and dilute it: consumers could no longer tell "upstream internals rev'd" from "my values must change".
- **Immediate per-dependency PRs.** Maximal granularity, but recreates the daily-noise problem; weekly grouping with `separateMajorMinor` keeps bisectability where it matters (majors are always separate).

## Consequences

- Steady state is roughly one automerged PR and release per week; humans only see major-update PRs and smoke/lint failures.
- The smoke test adds ~5–8 minutes to every PR and can flake on image pulls; automerge simply waits for a green re-run.
- Branch protection on `main` must require `lint` and `smoke`, or GitHub may automerge red PRs.
- Renovate cannot see the private docs-framework repo, so the `docs-check@vX` action pin stays manually maintained.
- ADR-0006's review-everything clause is narrowed: review is now mandatory only for majors; non-majors are reviewed by the CI gate.

## Confidence

High on the mechanism (prometheus-community and grafana-community run this exact pattern at much larger scale). Medium on the smoke test's flake rate in GitHub-hosted runners — if it becomes noisy, the fallback is keeping it required only for Renovate PRs while re-evaluating.
