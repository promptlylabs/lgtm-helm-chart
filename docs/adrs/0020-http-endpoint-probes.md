---
id: ADR-0020
type: adr
title: Opt-in HTTP endpoint probes on the cluster collector
status: accepted
created: 2026-11-17
updated: 2026-11-17
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring, reliability]
related:
  implements: []
  informed_by:
    - ./0015-grafana-managed-alerting.md
  supersedes: []
  superseded_by: []
  see_also:
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0018-targetallocator-secret-transport.md
    - ./0019-collector-crs-own-their-operator-posture.md
---

# ADR-0020 — Opt-in HTTP endpoint probes on the cluster collector

## Context

A platform running this chart had its Gateway refuse every connection for a day. After a CNI
upgrade the gateway's Envoy came up without listeners, and every pod stayed `Running`. No alert
fired.

Nothing the stack watched could have seen it:

- `up` only proves that each pod's `/metrics` endpoint answers when scraped directly by pod IP.
  Envoy's admin port answered throughout.
- The bundled rule packs (ADR-0015) watch the observability stack itself, not the workloads it
  serves.
- Nothing exercised the path a real caller takes: DNS → load-balancer VIP → Envoy listener →
  route → backend.

Platforms want to list a handful of URLs, have them checked from inside the cluster every 30
seconds, and be paged when one stops answering.

## Decision

### Probe from the cluster collector with `http_check`

The opentelemetry-collector-contrib `httpcheckreceiver` ships in the `otelcol-k8s` distribution the
chart's operator deploys. At the pinned operator 0.162.0 its manifest lists
`receiver/httpcheckreceiver v0.162.0`. At that version the component type is `http_check`
(`httpcheck` is a deprecated alias), so the chart renders `http_check`.

It runs on the **cluster collector**:

- It is a single replica, so each URL is checked once per interval, not once per node as on the
  node DaemonSet.
- It already exports metrics to Prometheus over OTLP, so the receiver joins the existing `metrics`
  pipeline and gets the same `resource` processing (`cluster`, `collector.mode`).

### Opt-in, with targets passed through verbatim

`collectors.cluster.httpcheck` holds `enabled: false`, `collectionInterval: 30s`, `timeout: 10s`
and `targets: []`. The receiver and its rule pack render only when the feature is enabled **and**
`targets` is non-empty, because the receiver refuses to start with none. One helper,
`lgtm.httpcheck.enabled`, gates both, so neither can render without the other. With the feature
off the render is byte-identical to the previous release.

Targets are passed through verbatim, so every field the receiver supports (`headers`, `tls.*`,
`proxy_url`, `body`, `validations`, …) works without the chart tracking the receiver's schema.
The values schema checks only that each target has `endpoint` or `endpoints`. The chart fills in
`timeout` where a target sets none, because the receiver's own default (30s) equals the default
interval.

### Alert on "no response at all", and separately on 5xx

The `httpcheck` rule pack has two rules:

- **HTTP endpoint unreachable** — critical, `for: 2m`. The latest check got no HTTP response:
  connection refused, timeout, TLS or DNS failure.
- **HTTP endpoint returning server errors** — warning, `for: 5m`. The latest check got a 5xx.

**Any HTTP status counts as reachable, 401 and 403 included.** An auth challenge or an
IP-allowlist rejection still proves that DNS, the VIP, the proxy listener and its route all
answered, which is the failure this exists to catch. It also means a probe never needs a
credential.

### Compare sample timestamps, not values

On every check the receiver writes:

- `httpcheck.duration`, always;
- `httpcheck.error = 1` (with `error.message`), only when no response came back;
- `httpcheck.status`, one point per status class. The class that matched is 1 and carries
  `http.status_code`; the others are 0 without it.

All of them share one timestamp.

Series ingested over OTLP carry no staleness markers, so a series that stops being written stays
readable for Prometheus's 5-minute lookback. A rule that reads values would keep seeing the last
`httpcheck.error = 1`, or the last 5xx `= 1`, for five minutes after the endpoint recovered.

Instead each rule asks whether the newest error (or 5xx) sample is at least as new as the newest
check:

```promql
max by ("http.url", "error.message") (timestamp({"httpcheck.error"}))
  >= on ("http.url") group_left
max by ("http.url") (timestamp({"httpcheck.duration"}))
```

The result is empty as soon as one check succeeds. It needs no range window sized to
`collectionInterval`. It also follows the chart's "positive means bad, `gt 0`" convention, since a
timestamp is positive, and its healthy result is empty, so `noDataState: OK`. `timestamp()` must
wrap a bare selector: on a computed vector it returns the evaluation time.

Verified end to end against `otelcol-k8s:0.162.0` and Prometheus 3.16 (`NoTranslation`,
`type-and-unit-labels`):

- A 403 target does not fire either rule.
- A 503 target fires only the server-errors rule.
- A target whose host stopped resolving fires the unreachable rule with
  `error.message="… no such host"`, while its stale `2xx = 1` series is still in the lookback.
- When the host returned, the rule cleared on the next check, while the stale error series was
  still readable.

## Consequences

- **The probe sees the in-cluster path only.**
  - It cannot see a failure that exists only outside the cluster: the cloud load balancer, public
    DNS, a WAF, a CDN, or a firewall.
  - kube-proxy and Cilium send in-cluster traffic for a `LoadBalancer` IP straight to the Service's
    endpoints (unless `ipMode: Proxy`), so the external load balancer is skipped.
  - It does cover DNS, the gateway's listener, its routes and the backend, which is where this
    failure was. The README says so and suggests an external uptime check for the outside path.
- **Egress is the consumer's to open.**
  - Neither the chart's NetworkPolicy, which fences the cluster target allocator and is
    ingress-only, nor the operator's collector policy, which is also ingress-only, restricts the
    collector's egress.
  - Under a default-deny egress policy the consumer needs a rule for DNS and each target. Because
    NetworkPolicy is evaluated after the Service DNAT, a target behind an in-cluster gateway is
    allowed by the gateway pods' labels, not by an `ipBlock` of its VIP. The README has an example.
- **Alert identity includes the error text and the status code.** `error.message` and
  `http.status_code` stay as labels so the annotations can name them. A change of error text
  (refused → timeout) or of code (502 → 503) starts a new alert instance. Go's messages for one
  failure mode are stable, so this is rare. Grafana also keeps a missing series' state for two
  evaluations before resolving it.
- **The rules go silent, rather than firing, when the cluster collector is down.** That case is
  covered by `lgtm-otelcol-cluster-absent`.
- Headers are rendered into the `OpenTelemetryCollector` CR in plain text. The values comments and
  README say to keep credentials out, and the reachability definition means no credential is
  needed.
- `scripts/validate_alerts.py` renders with `examples/values-httpcheck.yaml`, so the opt-in pack
  goes through the same uid, refId and dotted-label checks as the default packs.
- No values are removed. One block is added, and the chart takes a minor version.

## Alternatives considered

- **Blackbox exporter with a Probe CR.** Adds a Deployment, an image to track, and a second
  configuration surface. The chart's metrics path is OTLP push (ADR-0005), and `http_check` is
  already in the image.
- **The node collector.** Every URL would be checked once per node. The extra vantage points would
  catch node-local failures, but they multiply load on the target and alert noise.
- **Counting failed checks in a range window.** Ties the window to `collectionInterval`, and an
  interval longer than the window silently empties the rule. The timestamp comparison has no such
  coupling.
- **Treating 4xx as unreachable.** It would page on every auth or allowlist change, and would push
  consumers to put credentials in headers. 4xx proves the path works.
