---
id: ADR-0014
type: adr
title: Target allocator secret RBAC scope and overridable sizing
status: accepted
created: 2026-08-21
updated: 2026-08-21
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring]
related:
  implements: []
  informed_by:
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0013-collector-queue-backing-priority-and-securitycontext.md
  supersedes: []
  superseded_by: []
  see_also:
    - ./0012-first-party-component-dashboards.md
---

# ADR-0014 — Target allocator secret RBAC scope and overridable sizing

## Context

A node-collector target allocator on a production cluster sat in `CrashLoopBackOff` for **8 days** —
1839 restarts, roughly one every 3–6 minutes — and nobody noticed. The node allocator is what
discovers every ServiceMonitor *not* labelled `opentelemetry.io/scope: cluster` (ADR-0005), i.e.
essentially every workload monitor in the cluster, so the scrape-target set for the whole platform
flapped for the duration. A load test ran against that cluster with no usable metrics underneath it.

Two independent defects were behind it, and a third problem is why it went unseen for so long.

**1. The allocators had no `secrets` RBAC.** With `prometheusCR` enabled the allocator does not hand
monitor resolution to Prometheus — it resolves each selected monitor's `tlsConfig` / `basicAuth` /
`authorization` references itself. That means reading the Secrets those reference, which it does two
ways: a `PartialObjectMetadata` **informer** over secrets for change detection, and a direct `Get`
per reference when building the scrape config. The informer is the fatal one — without `list`/`watch`
its cache never syncs and the process exits:

```
{"level":"error","msg":"Failed to watch","type":"*v1.PartialObjectMetadata",
 "error":"failed to list *v1.PartialObjectMetadata: secrets is forbidden: User
 \"system:serviceaccount:observability:otel-node-collector-targetallocator\" cannot list
 resource \"secrets\" in API group \"\" in the namespace \"observability\""}
{"level":"error","msg":"Unable to sync caches","controller":"secrets"}
```

This reproduces **out of the box**: the trigger is the chart's own bundled kube-prometheus-stack
`prom-stack-operator` ServiceMonitor, whose `tlsConfig.ca` points at the `prom-stack-admission`
webhook CA Secret. No exotic configuration required.

**The comment in `rbac.yaml` is what hid it.** It claimed the rule set was "the canonical permission
set from the operator's allocator docs (with prometheusCR enabled, the operator's admission webhook
audits for exactly these rules and warns about anything missing)". The first half is true and the
second half is true — and the conclusion drawn from them was still wrong. `targetAllocatorCRPolicyRules`
in the operator's `internal/webhook/targetallocator_rbac.go` is exactly the list the chart carried,
and it contains **no `secrets` rule at all**. The audit could not warn about a permission it does not
know to ask for. A clean audit proved only "matches the audit list", never "sufficient at runtime".

**2. Allocator `resources` were hardcoded and unreachable.** Both collector templates ended their
`targetAllocator` block with a literal `64Mi` limit / `5m`+`32Mi` requests, and `values.yaml` had no
allocator keys at all — inconsistent with `priorityClassName`, `podSecurityContext` and
`securityContext` immediately above, which are all values-driven. Once the RBAC was fixed the
allocator got far enough to build the full target set and then **OOMKilled at 64Mi**
(`exitCode: 137`), on the same ~3-minute cadence, which is why the crashloop looked unchanged.
Corroborating datapoint from the same cluster: the *cluster* allocator, whose `scope: cluster`
selector gives it the smallest target set this chart produces, sits at **52Mi against the 64Mi
limit — 81%**, with no headroom.

**3. Nothing surfaced it.** The allocator is a separate Deployment; its health is not reflected in
the parent `OpenTelemetryCollector` CR status, so the ArgoCD Application stayed `Healthy` throughout.
The chart's own smoke test greps the two *collector* workloads for steady-state errors and never
looked at the allocators.

## Decision

**Grant secrets with a namespaced `Role` + `RoleBinding` in the release namespace, not a rule on the
shared ClusterRole.** This is not a narrowing compromise — it is the exact scope the allocator uses.
The operator builds the secrets metadata informer from
`cfg.PrometheusCR.GetSecretsAllowList(cfg.CollectorNamespace)`, which defaults to the allocator's own
namespace. Since `list`/`watch` on secrets cannot be bounded with `resourceNames` (the informer lists
the whole collection), a ClusterRole rule would mean cluster-wide Secret read for both allocator
ServiceAccounts in order to satisfy an informer that only ever watches one namespace.

**Expose the informer scope and the RBAC through a single key.** `collectors.targetAllocator.secretNamespaces`
sets both the CRs' `prometheusCR.secretNamespaces` and the set of Roles rendered, via one helper
(`lgtm.targetAllocator.secretNamespaces`). They must not drift: RBAC narrower than the informer is
the crashloop this ADR exists for. The helper always prepends the release namespace, because the
operator treats `secretNamespaces` as a *replacement* for the default rather than an addition — a
user listing only `team-a` would otherwise silently lose the release-namespace monitors, including
the `prom-stack-operator` one.

**Widen `configmaps` to `get, list, watch`.** A ConfigMap-sourced CA (`tlsConfig.ca.configMap`) is
resolved today by a direct `Get` — prometheus-operator's `assets.StoreBuilder.GetConfigMapKey`, no
informer — so `get` alone is genuinely sufficient at the pinned version. The widening is deliberate
future-proofing against the ConfigMap path growing the informer shape the Secret path already has,
accepting a cluster-wide ConfigMap read as the cost.

**Add `collectors.<node|cluster>.targetAllocator.resources`, keeping `64Mi`/`32Mi` as the default.**
Purely additive: the default render is byte-identical to 0.15.1, so no existing deployment changes
behaviour on upgrade. The sizing evidence is documented instead of encoded — the values comments and
the chart README carry the 52Mi-of-64Mi and OOMKill-at-19-target-groups numbers, so the next person
sizing this has a real datapoint rather than a guess.

**Correct the comment, and make the smoke test look at the allocators.** The comment now states what
the webhook audit does and does not prove. The smoke test waits on both allocator Deployments,
asserts a flat restart count, and fails on `secrets is forbidden` / `Unable to sync caches` in their
logs.

## Alternatives considered

- **`secrets: [get, list, watch]` on the shared ClusterRole.** Simplest, and it is what the reporter
  applied first. Rejected: cluster-wide Secret read for two ServiceAccounts, granted to satisfy an
  informer whose scope is a single namespace. The Role gives the identical runtime outcome at a
  fraction of the blast radius.
- **Namespaced Role with no opt-in key.** Fixes the reported crashloop and nothing else. Rejected:
  a workload monitor in another namespace that references a Secret is then silently skipped
  (`skipping object` warning, no scrape for that endpoint) with no supported way to fix it short of
  hand-applying RBAC beside the chart.
- **Two separate keys — one for `secretNamespaces` on the CRs, one for the extra Roles.** Rejected
  for the same reason the single key exists: the failure mode of the two disagreeing is a crashloop,
  and a values contract that lets a user express the broken combination is a bad contract.
- **Raising the default limit to `128Mi`.** Tempting given `64Mi` demonstrably OOMKills the node
  allocator on a normal cluster. Rejected for this change: it would make the upgrade non-additive and
  cost every install memory it may not need. The documented datapoint plus a reachable key puts the
  decision where the target-set size is actually known. Worth revisiting if the reports recur.

## Consequences

- The default install grants two ServiceAccounts `get`/`list`/`watch` on Secrets **in the release
  namespace only**. That namespace holds the observability stack's own Secrets — Grafana admin
  credentials, object-store credentials, the webhook CA — so this is not a nothing grant, but the
  allocators already run there and the alternative was the whole cluster.
- Installs whose monitors live outside the release namespace and use `tlsConfig`/`basicAuth` must
  now set `collectors.targetAllocator.secretNamespaces` explicitly. That is a visible, per-namespace
  decision rather than a blanket grant, which is the intent.
- Listed namespaces must already exist, or the Role/RoleBinding fail to apply. Helm does not create
  them and this chart deliberately does not either (ADR-0002).
- The `64Mi` default still OOMKills the node allocator on any cluster with a real monitor count. This
  is a knowingly accepted trade: additive upgrade now, documented sizing, and a key that makes the
  fix a one-line override.
- `collectors.targetAllocator` (shared) sits alongside `collectors.node.targetAllocator` (per
  collector). The split mirrors the objects: one shared ClusterRole and Role set, two Deployments.

## Confidence

High for the RBAC. The informer scope, the `secretNamespaces` semantics and the webhook audit list
were all read from the operator source at **v0.156.0** — the version the pinned
`opentelemetry-operator` 0.120.2 chart deploys — specifically
`cmd/otel-allocator/internal/watcher/promOperator.go`, `cmd/otel-allocator/internal/config/config.go`
and `internal/webhook/targetallocator_rbac.go`; `spec.targetAllocator.prometheusCR.secretNamespaces`
was confirmed present in the shipped `OpenTelemetryCollector` CRD, and the ConfigMap `Get`-not-watch
path in prometheus-operator v0.92.0's `assets.StoreBuilder`. The failure itself is reproduced by
production logs on a default install.

The residual risk is version drift: `secretNamespaces` is a comparatively recent field, and if a
future operator makes the secrets informer cluster-scoped by default, the namespaced Role becomes
insufficient and the crashloop returns. The smoke-test assertions on allocator restart count and
`secrets is forbidden` are what catch that on a dependency bump — that gate is the reason this ADR
treats the test change as part of the decision rather than a nicety.
