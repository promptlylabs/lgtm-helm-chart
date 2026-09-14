---
id: ADR-0019
type: adr
title: Collector CRs set their own NetworkPolicy and upgrade posture
status: accepted
created: 2026-09-14
updated: 2026-09-14
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring, reliability, security]
related:
  implements: []
  informed_by:
    - ./0018-targetallocator-secret-transport.md
    - ./0014-targetallocator-secret-rbac-and-sizing.md
  supersedes: []
  superseded_by: []
  see_also:
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0006-latest-upstream-versions-reviewed-bumps.md
---

# ADR-0019 — Collector CRs set their own NetworkPolicy and upgrade posture

## Context

Two `OpenTelemetryCollector` spec fields hand a decision to the operator when the chart leaves
them unset. On a production RKE2 cluster with Cilium (kube-proxy replacement), running chart
0.26.1, each one took telemetry down.

**`spec.networkPolicy.enabled`.** Operator 0.158 promoted `operand.networkpolicy` to beta. The gate
drives only the admission webhook, which stamps `enabled: true` onto any CR that leaves the field
unset, on every create or update. Generation reads just the field
(`internal/manifests/{collector,targetallocator}/networkpolicy.go`), so the stamp outlives the gate:
an operator downgraded to 0.157 with `--feature-gates=-operand.networkpolicy` still created both
policies. ADR-0018 set the field `false` on the cluster collector only; the node collector
inherited the stamp. The TargetAllocator policy the operator generates:

- admits any source on the allocator's ports;
- allows egress only to `/32` `ipBlock`s of the `kubernetes` EndpointSlice addresses, on the
  endpoint's `https` port, read once at operator startup (`discoverKubeAPIServer`). It has no DNS
  rule and no rule for the Service's ClusterIP.

On Cilium, node IPs resolve to reserved identities (host, remote-node, kube-apiserver) that CIDR
rules do not match, so the allocator's `kubernetes.default.svc` connection timed out:

```
NetworkPolicy/otel-node-collector-targetallocator-networkpolicy   [Ingress Egress]
  egress: ports [6443/TCP] to ipBlock 10.220.29.5/32, .6/32, .7/32
allocator log: dial tcp 172.30.0.1:443: i/o timeout   → CrashLoopBackOff
```

Every ServiceMonitor/PodMonitor scrape stopped for 13 minutes. On any CNI the rule also goes stale
when the control-plane IPs change, because the addresses are never re-read.

The operator also does not clean up after itself symmetrically. When the field flips to `false`,
the collector controller prunes its own policy, but the TargetAllocator controller calls
`reconcileDesiredObjects(..., nil)` with no owned types, so the allocator policy stays until the
TargetAllocator CR is deleted. Chart 0.21.0–0.25.x shipped operator 0.158 with no override on any
CR. Any cluster that reconciled on those releases therefore still carries
`otel-cluster-collector-targetallocator-networkpolicy`, and its allow-any ingress voids the ADR-0018
fence even though 0.26.0 turned the field off.

**`spec.upgradeStrategy`.** The webhook defaults it to `automatic`. `NeedsUpgrade`
(`pkg/collector/upgrade/upgrade.go`) is true whenever `status.version` is set and differs from the
operator's own collector version. `Reconcile` then runs the upgrade and returns
`RequeueAfter: 1s` before building the ConfigMap, workloads or status. For a CR recorded by a
*newer* operator, `ManagedInstance` changes nothing and logs at `V(4)` only, and `status.version`
is written only when empty. With the operator pinned to 0.157 under CRs recorded at 0.158.0, both
collectors requeued every second for 13 days with no INFO log, no error, no API write and ArgoCD
`Synced/Healthy`. The 0.23.0 byte cap (ADR-0017) never reached the collectors. Restarting the
operator does not help, because the trigger lives in the CR status. The only trace is
`controller_runtime_reconcile_total{controller="opentelemetrycollector",result="requeue_after"}`,
which this stack does not scrape.

## Decision

1. **Every collector CR renders both fields explicitly**, through `lgtm.collector.operatorPosture`,
   so none of them inherits a webhook default.

2. **Operator NetworkPolicies are off by default** (`collectors.operatorNetworkPolicies.enabled:
   false`). Which policies make sense depends on the CNI (native NetworkPolicy, Cilium's own
   policies), and this chart cannot know the target cluster, so its default has to work on all of
   them. The operator's allocator egress rule does not. A consumer on a CNI where it works can turn
   it on. They can also write their own policies outside the chart.

   The cluster collector stays off whenever `collectors.cluster.targetAllocator.networkPolicy`
   renders, whatever the switch says, because the operator's allow-any allocator policy would void
   that fence. That fence stays on by default: it is ingress-only and selects pods by the operator's
   labels, so it carries none of the egress rule's portability problem.

3. **`spec.upgradeStrategy: none` by default** (`collectors.upgradeStrategy`, one key for all CRs,
   since one operator manages them all). The upgrade routine migrates a CR's spec between operator
   versions. This chart renders the whole spec on every sync and reviews every operator bump
   (ADR-0006), so a migration here would either be reverted as drift or fight the next sync.
   `none` does not pin the collector: with `spec.image` unset the operator still runs its own
   default image.

4. **Stale allocator policies are documented, not deleted by the chart.** The README's 0.27.0 note
   carries the check and the `kubectl delete`.

## Consequences

- The chart works unchanged on any CNI. Node and faro collectors lose the operator's ingress policy,
  which was inert on the hostNetwork node pods anyway. The node allocator loses the apiserver egress
  restriction.
- A consumer who had disabled `collectors.cluster.targetAllocator.networkPolicy` used to get the
  operator's policies on the cluster collector. They now get none unless they also set
  `collectors.operatorNetworkPolicies.enabled`.
- With `none`, `status.version` stays at whatever was first recorded. Switching back to
  `automatic` with an operator older than that value re-arms the freeze, so the README's recovery
  patch is a prerequisite for switching.
- Clusters upgraded from 0.21–0.25 keep a stale allocator policy until someone deletes it. The
  chart cannot see it, since `lookup` is empty under ArgoCD. Until then the ADR-0018 fence is void
  on non-Cilium clusters, and the cluster allocator may crashloop on Cilium ones.
- The kind smoke test (kindnet) matches node IPs by `ipBlock`, so it cannot reproduce the Cilium
  failure. It asserts the rendered posture instead: no operator-managed NetworkPolicy exists, and
  every collector CR carries `upgradeStrategy: none`.
- No values are removed. Two keys are added, and the chart takes a minor version.

## Alternatives considered

- **Always off, no switch.** Simpler, but the values schema forbids any other override, so a
  consumer whose CNI handles the operator's policy would have no way to opt in.
- **Keep the ADR-0018 coupling** (operator policies return when the chart's fence is disabled). It
  made disabling the fence crashloop the cluster allocator on Cilium.
- **A hook Job that deletes stale operator policies.** Needs its own RBAC and image, and runs on
  every ArgoCD sync, all for a one-off cleanup.
- **Pin `spec.image` in the chart instead of changing `upgradeStrategy`.** Does not help: the trigger
  is the operator's collector version compared with `status.version`, not the image.
- **Alert on the freeze.** Needs the operator's metrics scraped (a new target and secure-metrics
  auth). Deferred: with `none` the freeze cannot arm.

## Confidence

High. Every mechanism was read in the operator source at v0.157.0 and v0.158.0, where the files
involved are identical: `internal/webhook/collector_webhook.go`,
`internal/manifests/{collector,targetallocator}/networkpolicy.go`, `cmd/operator/operator.go`
(`discoverKubeAPIServer`), `internal/controllers/{common,targetallocator_controller,opentelemetrycollector_controller}.go`,
`pkg/collector/upgrade/upgrade.go` and `internal/status/collector/collector.go`. Both failures were
observed on the production cluster described above, and both hand fixes (field off plus policy
deleted; `status.version` patched) held.
