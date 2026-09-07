---
id: ADR-0017
type: adr
title: Bound OTLP pushes in bytes and state Loki's ingest ceilings
status: accepted
created: 2026-09-04
updated: 2026-09-04
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
    - ./0009-collector-exporter-queue-batching.md
    - ./0015-grafana-managed-alerting.md
    - ./0016-k8s-event-timestamp-restamping.md
---

# ADR-0017 — Bound OTLP pushes in bytes and state Loki's ingest ceilings

## Context

A production cluster running 0.21.1 lost a batch of container logs. The node collector built a
7.26 MB OTLP push, Loki refused it, the exporter exhausted its retries and dropped everything:

```
HTTP Status Code 429, Message=ingestion rate limit exceeded for user fake
(limit: 4194304 bytes/sec) while attempting to ingest '1051' lines totaling '7256538' bytes
... no more retries left ... Dropping data. dropped_items: 1051
```

Measured tenant ingest at that moment was 0.78 MB/s — 19% of the limit. This was never a volume
problem, and no amount of headroom on `ingestion_rate_mb` would have prevented it.

**The chart was configured against itself.** `lgtm.collector.sendingQueue` (ADR-0009) batched with
`sizer: items`, `min_size: 1024` and no `max_size`, because it was written to mirror the deprecated
batch processor's `send_batch_size: 1024`. It inherited that processor's missing byte cap along
with the item count. Meanwhile the chart's Loki left `ingestion_burst_size_mb` at its stock 6.

`ingestion_burst_size_mb` is the token bucket's **capacity**, not a rate, so a single request larger
than it is rejected even against a completely idle Loki. That gives a hard, computable breaking
point:

    6,291,456 B burst / 1024 items = 6,144 B mean record size

Any deployment whose average log record exceeds ~6 KiB deadlocks the chart against itself. The
failing batch: 7,256,538 / 1051 = 6,904 B/record. Just over, exactly as predicted.

Two aggravating factors turned a bounded loss into an unbounded one:

**The batch is shared.** An exporter batch is not per-pod. All 1051 records died together, most of
them unrelated logs from other pods that happened to share the node and the flush window.

**The filelog `json_parser` had no bound of its own.** It ran `parse_from: body` with no `parse_to`,
whose stanza default is `attributes`, so every top-level key of every JSON log line became a log
attribute — while the chart's own `otlp_config` demotes non-indexed attributes to structured
metadata, which Loki caps per line at `max_structured_metadata_size` (64KB stock). Over-cap records
are dropped **whole**, body included, and silently: Loki answers OTLP with a partial success, so the
collector logs nothing. It also shipped every field twice, since `json_parser` leaves the raw body in
place. Cost on that cluster: 187 records / 27.5 MB in 24h, unattributed for over a week. The parser
existed only to expose `traceId`/`spanId` to `transform/trace_context`.

None of this was visible from the chart's own rules. `lgtm-loki-otlp-ingest-errors` described
"per-tenant ingestion limits and out-of-order or too-old timestamps" but selected
`status_code=~"5.."`. Rate limits are 429 and out-of-order/too-old are 400 — both 4xx. Over 24h on
`route="otlp_v1_logs"`: 204: 28291, 400: 76, 429: 55, **5xx: 0**. The rule read exactly zero for the
entire incident. And `loki_discarded_samples_total`, the only signal that exposes the silent
structured-metadata drops at all, had no rule anywhere in the chart.

## Decision

1. **Cap exporter batches in bytes, not items.** `lgtm.collector.sendingQueue` now emits
   `sizer: bytes` with `min_size`/`max_size`/`flush_timeout` from `collectors.batch`
   (1 MiB / 4 MiB / 10s). An item count bounds how many records go into a push; what Loki rejects is
   bytes, and mean record size is a property of the workload that the chart cannot know. `max_size`
   splits an oversized accumulation into conforming requests rather than rejecting it.

   `batch::sizer` is allowed to differ from `sending_queue::sizer`, which keeps its `requests`
   default; upstream's `min_size <= queue_size` constraint applies only when the two sizers match.
   One cap serves all seven exporters across all three collectors: 4 MiB is comfortably conservative
   for Prometheus OTLP and Tempo, neither of which has a comparable per-request ceiling, and a
   per-destination cap would triple the values surface to solve a problem only Loki has.

2. **State Loki's ingest ceilings instead of inheriting them.** `limits_config` now sets
   `ingestion_rate_mb: 4` and `ingestion_burst_size_mb: 6` — Loki's own stock values, so nothing
   changes today. The point is that `collectors.batch.maxSizeBytes` is chosen *against* the burst;
   leaving the burst implicit means a future upstream default change silently invalidates that
   choice, and the failure mode is a permanent 429.

   The ceilings are deliberately **not raised**. Measured load was 19% of the rate limit; the
   deadlock was a per-request capacity problem, and the byte cap fixes it without buying headroom
   that would also mask a genuinely runaway producer.

3. **Enforce the relationship at render time.** `lgtm.collector.validateBatchCeiling`, included from
   `templates/validations.yaml`, fails the render when `maxSizeBytes >= ingestion_burst_size_mb`.
   This chart configures both ends of the contract, so the contract should not be a comment. The
   guard stays quiet when it cannot know the answer — collectors off, Loki off (the endpoint is then
   an external Loki this chart does not configure), or a consumer who replaced `limits_config` and
   dropped the key — because a false failure would block a correct install.

4. **Scope JSON body parsing to trace context.** The filelog `json_parser` is off by default. The
   two IDs are extracted in `transform/trace_context` through OTTL's `cache`, per-record scratch
   that is never exported:

   ```yaml
   - merge_maps(cache, ParseJSON(body), "upsert") where IsMatch(body, "^\\{")
   - set(trace_id.string, cache["traceId"]) where cache["traceId"] != nil
   - set(span_id.string, cache["spanId"]) where cache["spanId"] != nil
   ```

   No attributes are created, so structured metadata cannot grow without bound, and JSON logs stop
   being shipped twice — which relieves (1) as well. `error_mode: ignore` is required rather than
   cosmetic: the processor default is `propagate`, which drops the record, and `ParseJSON` can fail
   on a body that starts with `{` but is not valid JSON.

   `collectors.node.flattenJsonLogBodies` restores the old behaviour. It exists because this chart
   exposes no override surface for collector config at all — `values.schema.json` sets
   `additionalProperties: false` throughout — so without the knob a consumer whose queries depend on
   the flattened fields would have to fork the chart.

5. **Alert on how Loki actually rejects.** `lgtm-loki-otlp-ingest-errors` keeps its uid and its 5xx
   selector, which is a valid rule that was merely mis-described; its title and description now say
   server errors, and point at the 4xx rule for rejections. Two rules are added, both burst-shaped
   after `lgtm-otelcol-export-drop-burst` (`for: 0`, 30m window, threshold 0):

   - `lgtm-loki-otlp-ingest-rejected-burst` — `sum by (status_code)` over 4xx on
     `route="otlp_v1_logs"`.
   - `lgtm-loki-discarded-samples-burst` — `sum by (reason)` over `loki_discarded_samples_total`.

   A ratio rule cannot see this class of failure: the incident measured 131 rejections against 28422
   pushes — 0.46%, under any sane ratio threshold, while dropping over a thousand records at a time.
   A 4xx is permanent data loss; a 5xx is retryable and goes back through the sending queue. They
   need different rule shapes, not a wider regex.

## Consequences

Log pushes are bounded by construction, and the bound is checked against the receiver at render
time rather than by convention. Both previously-silent failure modes report themselves.

Under load the collectors send more, smaller requests; metrics and traces batch by bytes rather than
by data-point count, with no correctness impact. A consumer who lowers `ingestion_burst_size_mb`
below 4 MiB now gets a hard render failure instead of a silent production deadlock — intended, but
it is a new way for `helm template` to fail.

**Breaking:** for JSON log lines, every field other than `traceId`/`spanId` disappears from Loki
structured metadata. The body is unchanged and the Grafana derived-field trace link still works.
Consumers who query the flattened fields set `collectors.node.flattenJsonLogBodies: true`, which
also restores the unbounded structured metadata — acceptable now that (5) makes those drops loud.

The two new rules fire on any cluster currently losing data. That is the point, and it also turns the
kind smoke test's "nothing is firing on a healthy stack" assertion into a live regression test for
decisions (1) and (4).

## Alternatives considered

**Expose the whole batch block through values and let consumers fix it.** The default would still be
broken, and a consumer cannot diagnose a 429 whose cause is 1024 × their own mean record size.

**Raise `ingestion_burst_size_mb` and keep `sizer: items`.** Moves the breaking point rather than
removing it; the deadlock returns for any workload whose mean record size clears the new ratio.

**Keep the flattening and raise `max_structured_metadata_size`.** Treats the symptom, pays
cardinality and storage cost for fields nothing in the chart reads, and leaves the drops silent.

**Widen the existing rule's regex to `[45]..`.** Insufficient, and wrong. Insufficient because
131/28422 = 0.46% stays under the 5% threshold. Wrong because it merges a retryable failure with
permanent data loss into one alert with one severity.

**Upstream `max_line_size_truncate: true`,** as one downstream consumer sets locally. Rejected.
`max_line_size` already defaults to 256KB, so that half of the override is a no-op; the real change
is truncation, which silently mutates log content. Rejection is bounded and, after (5), visible by
reason. Note it would also have been actively dangerous before (1): truncation converts bounded
per-line rejections into accepted 256 KiB lines that inflate batches past the burst ceiling, turning
a one-line loss into a 1051-record loss.
