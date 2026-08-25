---
id: ADR-0015
type: adr
title: Grafana-managed alerting — HA wiring and a baseline rule pack
status: accepted
created: 2026-08-25
updated: 2026-08-25
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring, reliability]
related:
  implements: []
  informed_by: []
  supersedes: []
  superseded_by: []
  see_also:
    - ./0003-standalone-grafana-with-sidecar-provisioning.md
    - ./0004-single-binary-minimal-footprint.md
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0012-first-party-component-dashboards.md
    - ./0014-targetallocator-secret-rbac-and-sizing.md
---

# ADR-0015 — Grafana-managed alerting: HA wiring and a baseline rule pack

## Context

Alertmanager is disabled in this chart and alerting is Grafana-managed: the Grafana alerts sidecar
is enabled by default and watches every namespace for ConfigMaps labelled `grafana_alert: "1"`
(ADR-0003). Two things were missing from that.

**The chart shipped no rules.** Operators got a fully provisioned alerting engine with nothing in
it. The cost is already recorded in ADR-0014: an `otel-node-collector-targetallocator` crashloop
ran for **8 days and ~1800 restarts** through a load test, flapping every ServiceMonitor in the
cluster in and out of the scrape set, and nobody noticed. Not through inattention — each target
allocator is a *separate* Deployment whose health is not reflected in the parent
`OpenTelemetryCollector` CR status, so ArgoCD reported `Healthy` the entire time, and the allocator
has no liveness probe that would have failed. The restart count was the only honest signal, and
nothing was watching it. The cause was a chart defect (ADR-0014), which makes the regression guard
the chart's responsibility rather than each consumer's.

**Grafana-managed alerting breaks silently at more than one replica.** Each Grafana replica runs
its own embedded Alertmanager. Without a gossip ring they do not deduplicate, so every alert
notifies once per replica. Nothing in Helm makes this conditional either: a parent chart cannot set
sub-chart values from a template, so "wire HA only when `grafana.replicas > 1`" is not expressible.
The failure mode is quiet — duplicate pages, not a crash — and it lands on whoever scales Grafana
first.

## Decision

### Wire unified-alerting HA unconditionally

`values.d/30-grafana.yaml` sets `headlessService: true` and a `grafana.ini` `[unified_alerting]`
block with `ha_listen_address` / `ha_advertise_address` / `ha_peers`. At the default single replica
this is one peer gossiping with itself — a headless Service and three ini keys — so it costs
nothing to leave on, and it is correct the moment anyone scales up.

Three details were settled by rendering the pinned sub-chart rather than from memory:

- **`POD_IP` needs no wiring of ours.** `grafana` 12.10.4 already injects it from
  `fieldRef: status.podIP` as the first env var of the container, unconditionally. Adding it via
  `envValueFrom` would render a second, duplicate entry. It also means the chart never touches
  `grafana.envValueFrom`, so a consumer's `GF_DATABASE_*` / `GF_AUTH_*` entries are untouched.
- **The addresses use `$__env{POD_IP}`, Grafana's own config expansion, not a Kubernetes
  `$(POD_IP)` reference in an env entry.** Both render correctly, but the env route works only
  because the chart's built-in `POD_IP` happens to precede `.Values.env`, which renders last —
  a detail upstream is free to change. The ini route depends on nothing but Grafana.
- **`ha_peers` is templated, not hardcoded.** The sub-chart runs every `grafana.ini` string through
  `tpl`, so `'{{ include "grafana.fullname" . }}-headless.{{ include "grafana.namespace" . }}.svc:9094'`
  resolves at render time and tracks `fullnameOverride` and `namespaceOverride`.

### Fail the render rather than ship a stack that double-notifies

`lgtm.grafana.validateAlertingHA`, invoked from `templates/validations.yaml` (which emits no
manifests, so the guard runs on every render), refuses `grafana.replicas > 1` unless both halves of
HA are present:

1. `ha_peers` is non-empty. Helm's map merge means a partial `unified_alerting` override keeps our
   keys, so this only fires on an explicit empty/null — belt and braces.
2. A **shared database** is configured. This is the half that is easy to miss: Grafana's HA
   alerting requires every replica to read the same database, and this chart defaults to ephemeral
   per-pod SQLite. The gossip ring alone is necessary but not sufficient.

The database check is deliberately permissive — `grafana.ini`'s own `[database]`, a
`GF_DATABASE_TYPE`/`GF_DATABASE_URL` env override, or any opaque `envFrom*` source all satisfy it.
A false pass is a consumer's problem to debug; a false failure would block a correct install.

This is the chart's first `fail` guard; validation elsewhere is `required` (faro) and
`values.schema.json`. Neither can express "this combination of values is wrong".

### Ship a baseline rule pack, gated per component

`alerts/` holds one file per component — `otel-collector`, `loki`, `prometheus`, `tempo` — each
provisioned only when that component is enabled, reusing the `$gate` map pattern from
`templates/grafana/dashboards.yaml` (ADR-0012). `lgtm.alerting.*` carries the shared knobs;
`templates/grafana/alerting.yaml` also passes `contactPoints` / `policies` / `templates` through
verbatim.

- **Rule files are rendered through `tpl`**, unlike the dashboards, so they can call a shared
  `lgtm.alerting.query` helper that emits the Grafana-managed A(instant query)/B(reduce last)/
  C(threshold) `data[]` triple. That is what keeps each rule to its title, expression and
  annotations instead of ~40 lines of provisioning boilerplate. The cost is that Grafana's own
  templating inside those files must be escaped from Helm.
- **Convention: write PromQL so a positive value means bad.** Every rule is then a `gt` threshold,
  the helper needs no per-rule operator, and a rule reads the same in the file as in the UI. For
  "should be present but isn't", `absent()` has the same polarity.
- **Expressions are lifted from the matching dashboard panels**, which ADR-0012 records as
  validated on a live kind stack, and thresholds from those panels' red steps. Nothing is invented:
  this stack is deliberately non-standard (ADR-0004, ADR-0005), and a plausible-looking metric name
  from an upstream mixin is exactly how a rule ends up silently never firing.
- **Contact points and policies gate together.** A notification policy routing to a receiver
  Grafana has never seen fails provisioning outright and takes the rest of the file with it, so
  policies are only emitted when contact points are too.

### What stays out

No contact points, no Slack or PagerDuty wiring, no site-specific stores, no NetworkPolicies. Where
alerts *go* is a property of the organisation running the stack, not of the stack. The chart ships
the rules and the plumbing; consumers add `lgtm.alerting.contactPoints` and `.policies`.

The target-allocator guard uses `k8s.container.restarts` from the cluster collector's `k8s_cluster`
receiver rather than the allocator's own `targetallocator_*` metrics, because nothing in this chart
scrapes the allocator Deployments — the collector self-telemetry ServiceMonitor selects the
collector's `:8888` monitoring Service, not the allocator's `:8080`. Adding that ServiceMonitor
would make the guard first-class and is worth doing, but it is a separate change with its own
cardinality and RBAC questions; restarts already catch both crashloop and OOMKill, which is the
failure this pack exists for.

## Consequences

- Every install upgrading to 0.18.0 starts **evaluating** these rules. They notify nothing until a
  contact point exists, but firing rules become visible in Grafana's Alerting UI — a visible
  change, deliberately, since a rule nobody can see is not a guard. `lgtm.alerting.enabled=false`
  opts out wholesale; `lgtm.alerting.exclude` drops individual packs.
- The rules read the stack's own self-metrics, so they are blind when
  `lgtm.metaMonitoring.enabled=true` reserves those ServiceMonitors for an external meta-monitoring
  stack — the same consequence ADR-0012 records for the component dashboards. Rate-based rules use
  `noDataState: OK` so this is quiet rather than noisy, and the per-component "not reporting" rules
  are what would surface it.
- `grafana.replicas > 1` now fails to render without an external database. That is a hard stop for
  anyone who had scaled Grafana up and was, unknowingly, already running split-brain alert state.
- `make validate-alerts` (`scripts/validate_alerts.py`) renders the chart and checks the
  provisioning schema and datasource references, mirroring what `validate_dashboards.py` does
  statically. It needs PyYAML and vendored sub-charts, so it runs after `make deps` in CI.
