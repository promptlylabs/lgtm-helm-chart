---
id: ADR-0016
type: adr
title: Re-stamp stale Kubernetes event timestamps in the cluster collector
status: accepted
created: 2026-08-28
updated: 2026-09-01
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
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0012-first-party-component-dashboards.md
    - ./0015-grafana-managed-alerting.md
---

# ADR-0016 — Re-stamp stale Kubernetes event timestamps in the cluster collector

## Context

The cluster collector ships Kubernetes events to Loki as structured logs: `k8s_events` receiver →
`resource/events` → `otlp_http/loki` (ADR-0005). On a production cluster running 0.19.0, that
pipeline lost a batch **every 30 minutes**, wholesale:

```
entry with timestamp 2026-08-27 01:12:10.90504 +0000 UTC ignored, reason:
'entry too far behind, entry timestamp is: 2026-08-27T01:12:10Z,
 oldest acceptable timestamp is: 2026-08-27T14:10:19Z'
... user 'fake', total ignored: 12 out of 15 for stream: {service_name="k8s-events"}
```

Thirteen hours behind, on a pipeline whose end-to-end lag is seconds. Three things compose into it:

**1. The receiver stamps the original event time, and only that.** `k8seventsreceiver` timestamps
each record via `k8sinventory.GetEventTimestamp()` (`internal/k8sinventory/utils.go`, contrib
v0.157.0), which reads `EventTime > LastTimestamp > FirstTimestamp` and **never**
`series.lastObservedTime`. There is no configuration that changes this.

**2. client-go replays every live event series every 30 minutes.** For `events.k8s.io`-style events
— `eventTime` set, `lastTimestamp: null`, plus a `series` block — the event broadcaster re-PATCHes
each live series on a fixed cadence (`refreshTime = 30 * time.Minute`, `k8s.io/client-go/tools/events`).
The receiver sees the watch `MODIFIED` and emits a record carrying the *original* `eventTime`. Each
replay is staler than the last, without bound. Legacy `core/v1` events are unaffected: their
`lastTimestamp` is refreshed on repeat, so their record time tracks reality.

**3. Loki rejects them and the exporter drops the batch.** Loki's ingester accepts unordered writes
only back to `max_chunk_age / 2` — one hour at the default two — and answers older entries with
HTTP 400. The OTLP exporter classifies 400 as `Permanent`, so it does not retry and the *whole*
batch is discarded, including the fresh entries that shared it (12 of 15, above). The queue and
retry machinery of ADR-0009 are no help: permanent means permanent.

**Nothing in the chart surfaced it.** The bundled `lgtm-otelcol-exporter-failures` rule (ADR-0015)
is `rate(...[5m]) > 0` with `for: 10m`. A burst every 30 minutes keeps the rate non-zero for about
five minutes: the rule reaches `Pending`, the rate returns to zero, the timer resets. Forever. It
watched this exact defect for months and never fired, and every install carries that blind spot —
the failure shape it cannot see is precisely the shape of a periodic permanent rejection.

## Decision

**Re-stamp event records as observed-now, in a `transform/events` processor on the logs pipeline.**

```yaml
transform/events:
  error_mode: ignore
  log_statements:
    - context: log
      statements:
        - set(time, Now()) where UnixNano(Now()) - time_unix_nano > 600000000000
```

Three details are load-bearing:

- **The int64 comparison is mandatory.** OTTL's comparison table (`pkg/ottl/LANGUAGE.md`) allows
  only `==` and `!=` between two `time.Time` values. The natural spelling,
  `where time < Now() - Duration("10m")`, is therefore always false — and it **parses without
  error**, so the collector starts clean and the statement silently never fires. We confirmed this
  against the 0.157.0 `opentelemetry-collector-k8s` image: `otelcol validate` accepts it. A guard
  that looks provisioned and is dead is the same trap ADR-0015 records twice for the alert pack.
- **The 10-minute threshold, not zero.** `600000000000` ns sits comfortably inside Loki's one-hour
  cutoff and well outside any normal pipeline lag, so genuine ordering within a batch is preserved
  and only records that are already unshippable are touched.
- **Nothing is destroyed.** The receiver already preserves the original as the
  `k8s.event.start_time` attribute (`k8s_event_start_time` in Loki, since Loki's OTLP ingestion
  sanitises attribute names — the spelling split ADR-0015 documents). Occurred-at is still queryable.

**Unconditional, with no values knob.** This is a property of the receiver and of client-go, not of
any particular cluster. Every install with `collectors.cluster.enabled` hits it the moment an
`events.k8s.io` producer runs. A knob would only let an install stay broken.

**The companion alert rule is part of this decision, not a nicety.** The stable Grafana uid remains
`lgtm-otelcol-export-drop-burst`, but its title and annotations call the condition an export failure:
the send-failed counters include permanent failures such as this incident's 400 and retryable failures
such as a 5xx that enters the sending queue and may later succeed. The rule uses `increase(...[30m])`
with `for: 0`, alongside the existing 5m-rate rule which stays as the sustained-failure signal. Both
rules group by `job`, `pod` and `exporter`, so a notification identifies the affected collector and
export path. Same reasoning as ADR-0014 treating its smoke-test assertions as part of the fix: shipping
the fix without closing the detection gap leaves the next periodic-failure bug just as invisible as
this one was. Its lookback is widened to `from: 1800` to cover the `[30m]` selector, mirroring the
Target Allocator rule's `from: 3600` for `[1h]`.

## Alternatives considered

- **`k8s_events`' `dedup_interval: -1`** (new in contrib 0.157.0). Silences the 400s, and it is the
  first thing the knob's name suggests. Rejected: it drops *all* `MODIFIED` events, which includes
  the legacy `core/v1` repeats — `BackOff`, `FailedMount`, `FailedScheduling` — that are the most
  operationally useful events the receiver emits, and whose timestamps were never broken. Trading a
  real signal away to suppress a symptom.
- **A positive `dedup_interval`.** Throttles the replay rate without touching the timestamps, so the
  entries that do get through are still hours stale and still rejected. It reduces how often the
  400 happens and fixes nothing.
- **Raising Loki's `max_chunk_age`.** Buys a fixed number of hours against a staleness that grows
  without bound for as long as an event series stays live, at the cost of larger in-memory chunks
  for every stream in the cluster. It postpones the bug and taxes everything else.
- **A values knob to opt in.** Rejected under the reasoning above: the correct setting is the same
  on every cluster, so a knob adds a way to be wrong and nothing else.
- **Fixing it upstream in the receiver.** Worth doing, and not mutually exclusive — but a contrib
  change plus a release plus an operator bump is quarters away, and this drops data today. The
  processor stays harmless if the receiver later reads `series.lastObservedTime`.

## Consequences

- **`time` on `k8s-events` records now means observed-at, not occurred-at**, for any record more
  than ten minutes old. Dashboards and queries that need the original must read
  `k8s_event_start_time`. This is the deliberate trade: an approximate timestamp that arrives beats
  an exact one that is dropped along with its batchmates.
- Records older than ten minutes from *any* cause are re-stamped, not just replayed series — a
  collector restarted after a long outage replays its queue with rewritten times. That is the same
  trade, and the alternative is the same 400.
- The burst rule can fire on a single export failure anywhere in the stack. That is intended; it is
  a `warning`. A permanent 4xx drops the rejected batch, while a retryable 5xx goes through the
  sending queue and may succeed, so the alert does not claim every failure is already data loss.
  Installs that want only sustained failure can pause it by uid.
- The alert pack now carries two rules over the same metrics with different windows. The header
  comment in `alerts/otel-collector.yaml` explains why, so neither is later removed as a duplicate.
- One more processor in the logs pipeline. Negligible: the events volume is a handful of records
  per second and OTTL runs per record.

## Confidence

High on the causal chain. Each link was read at the pinned version rather than inferred:
`GetEventTimestamp` in contrib v0.157.0's `internal/k8sinventory/utils.go`, `refreshTime` in
`k8s.io/client-go/tools/events`, and Loki's `max_chunk_age / 2` unordered-write window. The failure
itself is a production log line on a default install, and the split between `events.k8s.io` and
`core/v1` behaviour predicts exactly which events appear in the rejected batches.

High on the OTTL, and specifically verified rather than reasoned about — the trap here is a
statement that parses and does nothing. Both the shipped statement and the broken `time <` form were
run through `otelcol validate` on the 0.157.0 `opentelemetry-collector-k8s` image: the shipped form
passes, the broken form *also* passes, and a deliberately undefined function fails — which is what
establishes that the validator parses OTTL at all and that the check means something.

The residual risk is version drift. If the receiver gains a `lastObservedTime` path or the field
semantics change, the processor becomes redundant; it stays harmless, because a record that is
already fresh fails the ten-minute predicate. The signal that would tell us is the burst rule going
quiet, which is the other half of this change.
