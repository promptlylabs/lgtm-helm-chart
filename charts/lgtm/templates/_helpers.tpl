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
