{{/*
Common labels for umbrella-owned resources.
*/}}
{{- define "lgtm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: lgtm
{{- end }}

{{/*
Endpoint helpers — the single source of truth for cross-component URLs.

Each helper honours the matching lgtm.endpoints.* override; otherwise it
computes the in-cluster FQDN from the sub-chart's fullnameOverride (read back
from values, so a renamed component keeps endpoints in sync), the release
namespace, and lgtm.clusterDomain.

Note: literal endpoints inside sub-chart values (tempo remote-write, loki OTLP
env) cannot use these helpers — Helm can't template sub-chart values. Those use
same-namespace short names and are flagged in the values fragments.
*/}}

{{- define "lgtm.prometheus.serviceName" -}}
{{- printf "%s-prometheus" (index .Values "kube-prometheus-stack" "fullnameOverride" | default (printf "%s-kube-prometheus-stack" .Release.Name)) -}}
{{- end -}}

{{- define "lgtm.prometheus.endpoint" -}}
{{- .Values.lgtm.endpoints.prometheus | default (printf "http://%s.%s.svc.%s:9090" (include "lgtm.prometheus.serviceName" .) .Release.Namespace .Values.lgtm.clusterDomain) -}}
{{- end -}}

{{/* Prometheus native OTLP ingest: POST <endpoint>/api/v1/otlp/v1/metrics */}}
{{- define "lgtm.prometheus.otlpEndpoint" -}}
{{- include "lgtm.prometheus.endpoint" . }}/api/v1/otlp
{{- end -}}

{{- define "lgtm.loki.serviceName" -}}
{{- index .Values "loki" "fullnameOverride" | default (printf "%s-loki" .Release.Name) -}}
{{- end -}}

{{/* Loki HTTP API (queries + OTLP ingest at /otlp) — no gateway, see ADR-0004 */}}
{{- define "lgtm.loki.endpoint" -}}
{{- .Values.lgtm.endpoints.loki | default (printf "http://%s.%s.svc.%s:3100" (include "lgtm.loki.serviceName" .) .Release.Namespace .Values.lgtm.clusterDomain) -}}
{{- end -}}

{{- define "lgtm.loki.otlpEndpoint" -}}
{{- include "lgtm.loki.endpoint" . }}/otlp
{{- end -}}

{{- define "lgtm.tempo.serviceName" -}}
{{- index .Values "tempo" "fullnameOverride" | default (printf "%s-tempo" .Release.Name) -}}
{{- end -}}

{{/* Tempo query API (HTTP, port 3200) */}}
{{- define "lgtm.tempo.queryEndpoint" -}}
{{- .Values.lgtm.endpoints.tempoQuery | default (printf "http://%s.%s.svc.%s:3200" (include "lgtm.tempo.serviceName" .) .Release.Namespace .Values.lgtm.clusterDomain) -}}
{{- end -}}

{{/* Tempo OTLP gRPC ingest (no scheme — gRPC target) */}}
{{- define "lgtm.tempo.otlpGrpcEndpoint" -}}
{{- .Values.lgtm.endpoints.tempoOtlpGrpc | default (printf "%s.%s.svc.%s:4317" (include "lgtm.tempo.serviceName" .) .Release.Namespace .Values.lgtm.clusterDomain) -}}
{{- end -}}

{{- define "lgtm.pyroscope.serviceName" -}}
{{- (index .Values "pyroscope" "pyroscope" "fullnameOverride") | default (printf "%s-pyroscope" .Release.Name) -}}
{{- end -}}

{{- define "lgtm.pyroscope.endpoint" -}}
{{- .Values.lgtm.endpoints.pyroscope | default (printf "http://%s.%s.svc.%s:4040" (include "lgtm.pyroscope.serviceName" .) .Release.Namespace .Values.lgtm.clusterDomain) -}}
{{- end -}}

{{/*
Exporter sending-queue batching — replaces the deprecated batch processor.

Upstream is retiring the batch processor: it acks data before the exporter
confirms delivery and swallows per-batch errors, which breaks backpressure.
Batching instead lives in each real exporter's sending queue, where it shares
the queue's retry and backpressure. The sending queue and retry_on_failure are
on by collector default — pinned here for visibility.

sizer:bytes, not items (ADR-0017). This helper originally used
sizer:items/min_size:1024 to mirror the old batch processor's send_batch_size,
and inherited that processor's missing byte cap along with it. An item count
bounds how many records go into a push; what Loki rejects is BYTES. With no
max_size, any cluster whose mean log record exceeded
ingestion_burst_size_mb/1024 (~6 KiB against Loki's stock 6 MB burst) built
pushes the chart's own Loki could never accept — at any ingest rate, because
the burst is the token bucket's capacity, not a rate. So the cap is in bytes,
and it is checked against that burst at render time (see
lgtm.collector.validateBatchCeiling). max_size splits an oversized accumulation
into conforming requests rather than rejecting it.

int64 on the byte values is load-bearing: Helm decodes YAML numbers as
float64, so an unwrapped 1048576 renders as 1.048576e+06 and the collector
rejects the config at startup.

batch::sizer is allowed to differ from sending_queue::sizer — the field exists
to allow exactly that — so the queue keeps its `requests` default. Upstream's
"min_size <= queue_size" constraint applies only when the two sizers match.

Include once per real exporter (never the debug exporter) at the exporter's
sub-key indent, e.g. with nindent 8.

Takes a dict: `root` (the root context) and `storage` (whether this collector
defines the file_storage/queue extension). Only the node and cluster collectors
do; faro has no queue volume, so it must pass storage=false or it would name an
extension that does not exist and fail config validation at startup.
*/}}
{{- define "lgtm.collector.sendingQueue" -}}
{{- $root := .root -}}
{{- $batch := $root.Values.collectors.batch -}}
sending_queue:
  enabled: true
  {{- if and $root.Values.collectors.persistentQueue.enabled .storage }}
  # Durable on-disk queue (ADR-0011) — survives collector restarts. The
  # file_storage/queue extension and its volume are defined on each collector.
  storage: file_storage/queue
  {{- end }}
  batch:
    sizer: bytes
    min_size: {{ int64 $batch.minSizeBytes }}
    max_size: {{ int64 $batch.maxSizeBytes }}
    flush_timeout: {{ $batch.flushTimeout }}
retry_on_failure:
  enabled: true
{{- end -}}

{{/*
Node collector target-allocator scope selector (ADR-0005).

Selects which ServiceMonitors/PodMonitors the node collector scrapes, keyed on
lgtm.metaMonitoring.enabled:

  enabled (meta stack present) → DoesNotExist: scrape only unlabelled (app)
    monitors. scope=observability is left for the external meta stack;
    scope=cluster is the cluster collector's.
  disabled (default, no meta stack) → NotIn [cluster]: scrape everything except
    cluster-scoped monitors. NotIn also matches monitors that lack the label, so
    app AND scope=observability targets are both picked up — the stack
    self-monitors. scope=cluster still routes to the cluster collector.

Include under a matchExpressions: key, e.g. with nindent 10.
*/}}
{{- define "lgtm.node.scopeMatchExpressions" -}}
{{- if .Values.lgtm.metaMonitoring.enabled -}}
- key: opentelemetry.io/scope
  operator: DoesNotExist
{{- else -}}
- key: opentelemetry.io/scope
  operator: NotIn
  values: [cluster]
{{- end -}}
{{- end -}}

{{/*
Namespaces the target allocators may read Secrets in.

Always includes the release namespace, because the operator treats
prometheusCR.secretNamespaces as a REPLACEMENT for the default (which is the
allocator's own namespace), not an addition — GetSecretsAllowList only falls
back to the collector namespace when the list is empty. Setting the values key
without this prepend would silently stop the allocator resolving the monitors in
its own namespace, including the bundled prom-stack-operator one.

Single source of truth for the CRs' prometheusCR.secretNamespaces and the Roles
in collectors/rbac.yaml — the informer scope and the RBAC must match or the
allocator crashloops on a cache it is not allowed to sync. Emits a YAML list;
read it back with fromYamlArray to range over it.
*/}}
{{- define "lgtm.targetAllocator.secretNamespaces" -}}
{{- prepend .Values.collectors.targetAllocator.secretNamespaces .Release.Namespace | uniq | toYaml -}}
{{- end -}}

{{/*
Thanos helpers (ADR-0010). The umbrella-owned Query/Store Gateway/Compactor use
fixed names (one release per cluster, ADR-0001/0002), so the endpoints below are
plain service DNS names, not release-prefixed.
*/}}

{{/* Fully-qualified image reference for the umbrella-owned Thanos components. */}}
{{- define "lgtm.thanos.image" -}}
{{- $img := .Values.thanos.image -}}
{{- if $img.registry -}}
{{- printf "%s/%s:%s" $img.registry $img.repository $img.tag -}}
{{- else -}}
{{- printf "%s:%s" $img.repository $img.tag -}}
{{- end -}}
{{- end -}}

{{/* Thanos Query HTTP (Prometheus-API) endpoint. */}}
{{- define "lgtm.thanos.queryEndpoint" -}}
{{- printf "http://thanos-query.%s.svc.%s:9090" .Release.Namespace .Values.lgtm.clusterDomain -}}
{{- end -}}

{{/*
StoreAPI of the Prometheus Thanos sidecar, federated by Query. Defaults to a DNS
SRV lookup of the headless Service that kube-prometheus-stack's thanosService
creates ("<fullnameOverride>-thanos-discovery", gRPC port name "grpc").
*/}}
{{- define "lgtm.thanos.sidecarStoreEndpoint" -}}
{{- $prom := index .Values "kube-prometheus-stack" "fullnameOverride" | default (printf "%s-kube-prometheus-stack" .Release.Name) -}}
{{- .Values.thanos.sidecarStoreEndpoint | default (printf "dnssrv+_grpc._tcp.%s-thanos-discovery.%s.svc.%s" $prom .Release.Namespace .Values.lgtm.clusterDomain) -}}
{{- end -}}

{{/*
Read endpoint for Grafana's Prometheus datasource: Thanos Query when the query
stack is enabled (and no explicit lgtm.endpoints.prometheus override), otherwise
the in-cluster Prometheus. Write paths (OTLP ingest, Tempo remote-write) keep
targeting Prometheus directly — Query is read-only.
*/}}
{{- define "lgtm.metrics.readEndpoint" -}}
{{- if and .Values.thanos.enabled .Values.thanos.query.enabled (not .Values.lgtm.endpoints.prometheus) -}}
{{- include "lgtm.thanos.queryEndpoint" . -}}
{{- else -}}
{{- include "lgtm.prometheus.endpoint" . -}}
{{- end -}}
{{- end -}}

{{/*
Grafana unified-alerting HA validation.

Alerting is Grafana-managed and on by default, so more than one Grafana replica
means more than one Alertmanager unless they are wired into a gossip ring. The
chart wires that ring in values.d/30-grafana.yaml (headlessService + the
grafana.ini [unified_alerting] block), but nothing stops a consumer replacing
that block wholesale — sub-chart values deep-merge per key, and re-declaring
`unified_alerting` drops what we set. This fails the render instead of shipping
a stack that double-notifies.

Two checks, both inert at one replica:

  1. ha_peers must be set. The chart sets it, so empty means it was overridden.
  2. There must be a shared database. Grafana's HA Alertmanager requires every
     replica to read the same database, and this chart defaults to per-pod
     ephemeral SQLite — so the gossip ring alone is not enough.

The database check is deliberately permissive: it accepts grafana.ini's own
[database] block, a GF_DATABASE_* env override, or any opaque envFrom source we
cannot introspect. A false pass is a consumer's problem to debug; a false
failure would block a correctly-configured install.

Included from templates/validations.yaml, which renders on every pass.
*/}}
{{- define "lgtm.grafana.validateAlertingHA" -}}
{{- if and .Values.grafana.enabled (gt (int (.Values.grafana.replicas | default 1)) 1) -}}
{{- $ini := index .Values.grafana "grafana.ini" | default dict -}}
{{- $ua := get $ini "unified_alerting" | default dict -}}
{{- if not (get $ua "ha_peers") -}}
{{- fail (printf "grafana.replicas is %v but grafana.grafana\\.ini.unified_alerting.ha_peers is empty. The chart sets it by default, so an empty value means the unified_alerting block was overridden — re-declaring a sub-chart key replaces it rather than merging into it. Without a gossip ring every replica runs its own Alertmanager and every alert notifies once per replica. Restore ha_peers (see values.d/30-grafana.yaml) or set grafana.replicas back to 1." (.Values.grafana.replicas)) -}}
{{- end -}}
{{- $db := get $ini "database" | default dict -}}
{{- $env := .Values.grafana.env | default dict -}}
{{- $shared := or (has (get $db "type" | toString) (list "mysql" "postgres")) (hasKey $env "GF_DATABASE_TYPE") (hasKey $env "GF_DATABASE_URL") .Values.grafana.envFromSecret .Values.grafana.envFromSecrets .Values.grafana.envFromConfigMaps -}}
{{- if not $shared -}}
{{- fail (printf "grafana.replicas is %v but no shared database is configured. Grafana's HA alerting requires every replica to share one database, and this chart defaults to per-pod ephemeral SQLite — each replica would keep its own alert state, silences and dashboards. Point grafana.grafana\\.ini.database at an external MySQL/PostgreSQL (examples/values-azure.yaml shows the PostgreSQL pattern) or set grafana.replicas back to 1." (.Values.grafana.replicas)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Batch ceiling guard — the collector byte cap must stay under Loki's ingestion
burst (ADR-0017).

This chart owns both ends of the contract: it sets the exporters' batch
max_size AND the Loki limits_config that receives the batch. Loki's
ingestion_burst_size_mb is the token bucket's CAPACITY, so a single push larger
than it is rejected with 429 even against a completely idle Loki. The exporter
then exhausts retry_on_failure and drops the whole batch — including every
unrelated record that happened to share it. That is not a load failure, and no
amount of headroom on ingestion_rate_mb prevents it.

Deliberately quiet when it cannot know the answer: collectors off, Loki off
(the endpoint is then an external Loki this chart does not configure), or a
consumer who replaced limits_config and dropped the key. A false failure would
block a correctly-configured install.

Included from templates/validations.yaml, which renders on every pass.
*/}}
{{- define "lgtm.collector.validateBatchCeiling" -}}
{{- if and .Values.collectors.enabled .Values.loki.enabled -}}
{{- $inner := .Values.loki.loki | default dict -}}
{{- $limits := get $inner "limits_config" | default dict -}}
{{- $burst := get $limits "ingestion_burst_size_mb" -}}
{{- if $burst -}}
{{- $ceiling := mul (int $burst) 1048576 -}}
{{- $max := int .Values.collectors.batch.maxSizeBytes -}}
{{- if ge $max $ceiling -}}
{{- fail (printf "collectors.batch.maxSizeBytes is %v but loki.loki.limits_config.ingestion_burst_size_mb is %v (%v bytes), so the collectors can build a push this chart's own Loki will never accept. The burst is the token bucket's CAPACITY, not a rate: a single request larger than it is rejected with 429 even against a completely idle Loki, the exporter exhausts retry_on_failure, and the entire batch is dropped — unrelated records included. Lower collectors.batch.maxSizeBytes below %v bytes, or raise loki.loki.limits_config.ingestion_burst_size_mb." $max $burst $ceiling $ceiling) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Grafana-managed alert rule query — the A/B/C data[] triple (ADR-0015).

Every bundled rule in alerts/ is the same shape: run one instant PromQL query,
reduce it to its last value, compare that to a threshold. Emitting it from here
keeps each rule down to its title, its expression and its annotations.

  A  instant PromQL against lgtm.alerting.datasourceUid
  B  reduce(last) over A
  C  threshold: B > `threshold` (default 0)

CONVENTION: write the PromQL so that a POSITIVE VALUE MEANS BAD. Every bundled
rule is then `gt 0` with no per-rule operator, and a rule reads the same way in
the file as it does in the Grafana UI. For "should be present but isn't", use
absent() — it yields 1 exactly when the series is missing, which is the same
polarity and never lands in NoData.

Takes a dict:
  root       (required) the root context
  expr       (required) the PromQL for A
  threshold  (optional) evaluator parameter for C, default 0
  from       (optional) relativeTimeRange lookback in seconds, default 600

Include at the `data:` key's indent, e.g. with nindent 10.
*/}}
{{- define "lgtm.alerting.query" -}}
{{- $root := .root -}}
- refId: A
  relativeTimeRange:
    from: {{ .from | default 600 }}
    to: 0
  datasourceUid: {{ $root.Values.lgtm.alerting.datasourceUid | quote }}
  model:
    refId: A
    editorMode: code
    instant: true
    range: false
    expr: {{ .expr | quote }}
- refId: B
  datasourceUid: __expr__
  model:
    refId: B
    type: reduce
    reducer: last
    expression: A
- refId: C
  datasourceUid: __expr__
  model:
    refId: C
    type: threshold
    expression: B
    conditions:
      - evaluator:
          type: gt
          params: [{{ .threshold | default 0 }}]
{{- end -}}

{{/*
Labels for a bundled alert rule: the rule's own labels with
lgtm.alerting.commonLabels merged over them, so consumers can tag every shipped
rule for routing without editing any of them.

commonLabels wins on a key collision: the rule's own labels are the chart's
default, and an explicit consumer setting should beat a chart default.

Takes a dict: `root` (the root context) and `labels` (the rule's own map).
Include at the `labels:` key's indent, e.g. with nindent 10.
*/}}
{{- define "lgtm.alerting.labels" -}}
{{- $common := .root.Values.lgtm.alerting.commonLabels | default dict -}}
{{- toYaml (mergeOverwrite (dict) (.labels | default dict) $common) -}}
{{- end -}}
