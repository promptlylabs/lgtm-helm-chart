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
the queue's retry and backpressure. sizer:items + min_size/flush_timeout mirror
the batch processor's old send_batch_size (1024) / timeout (10s); without
sizer:items, min_size would count requests, not data points. The sending queue
and retry_on_failure are on by collector default — pinned here for visibility.
Include once per real exporter (never the debug exporter) at the exporter's
sub-key indent, e.g. with nindent 8.
*/}}
{{- define "lgtm.collector.sendingQueue" -}}
sending_queue:
  enabled: true
  {{- if .Values.collectors.persistentQueue.enabled }}
  # Durable on-disk queue (ADR-0011) — survives collector restarts. The
  # file_storage/queue extension and its volume are defined on each collector.
  storage: file_storage/queue
  {{- end }}
  batch:
    sizer: items
    min_size: 1024
    flush_timeout: 10s
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
