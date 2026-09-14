---
id: ADR-0018
type: adr
title: How target allocators deliver Secret-sourced credentials to the collectors
status: accepted
created: 2026-09-14
updated: 2026-09-14
owners: [ca-moes]
visibility: internal
audience: [platform-engineer]
tags: [monitoring, security]
related:
  implements: []
  informed_by:
    - ./0005-otlp-push-scrapeless-prometheus.md
    - ./0014-targetallocator-secret-rbac-and-sizing.md
  supersedes: []
  superseded_by: []
  see_also:
    - ./0006-latest-upstream-versions-reviewed-bumps.md
    - ./0019-collector-crs-own-their-operator-posture.md
---

# ADR-0018 — How target allocators deliver Secret-sourced credentials to the collectors

## Context

kube-prometheus-stack **90.0.0** (upstream #7238) changed how its control-plane ServiceMonitors
authenticate. Up to 89.x the apiserver monitor carried
`bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token` — a *path*. The target
allocator copied the path into the scrape config, and the collector read the token from its own
pod: its own ServiceAccount, which `rbac.yaml` already grants `/metrics`. No credential ever moved
between pods. From 90.0.0 the same monitors reference a Secret instead
(`authorization.credentials → prom-stack-prometheus-token`, a long-lived ServiceAccount token that kps
now renders by default) and take their CA from the `kube-root-ca.crt` ConfigMap. The motivation
upstream is sound — file references are rejected by `arbitraryFSAccessThroughSMs.deny` and by
Alloy — but it assumes the scraper reads Secrets itself, which Prometheus does and our collectors do
not (ADR-0005).

Here the allocator resolves the Secret (ADR-0014 gave it the RBAC) and hands the resulting scrape
config to the collector over `GET /scrape_configs`. On the plain-HTTP listener it marshals every
Prometheus `Secret`-typed field as `<secret>`. The real values are served only on the mTLS listener
or when `allowInsecureAuthSecrets` is set (`cmd/otel-allocator/internal/server/server.go`:
`if c.Request.TLS != nil || s.allowInsecureAuthSecrets`). So the collector sent
`Authorization: Bearer <secret>` and every apiserver scrape failed `401 Unauthorized`. TLS kept
working — a CA is a plain string, not a `Secret` field, so it passes through unmasked — which is why
the symptom was 401 rather than an x509 error. The CoreDNS monitor received the same change; CoreDNS
ignores the header, so it failed silently rather than loudly.

The smoke test caught it on the Renovate PR: "Check collectors for steady-state errors" failed on the
repeated `Failed to scrape Prometheus endpoint … 401` warnings for `job="apiserver"`.

The masking was not new — any workload monitor with `basicAuth` or a bearer Secret has always reached
the collectors as `<secret>`. kps 90 made it reproduce out of the box.

## Decision

**Keep the kube-prometheus-stack ServiceMonitors as upstream ships them, and make the cluster
allocator deliver their credentials:**

- `collectors.cluster.targetAllocator.allowInsecureAuthSecrets: true` by default. This allocator
  selects only `scope: cluster` monitors (ADR-0005), so the only credential it serves out of the box
  is `prom-stack-prometheus-token`.
- A **NetworkPolicy** on the cluster allocator admits only the cluster collector's pods
  (`collectors.cluster.targetAllocator.networkPolicy`, on by default, with `extraIngress` for
  additional sources). Selectors are the operator's own `SelectorLabels` — `component` plus
  `instance: <namespace>.<cr-name>`. It must be the **only** policy on that allocator. The operator
  generates its own whenever the CR carries `spec.networkPolicy.enabled: true`, and operator 0.158
  made its webhook stamp that onto any CR that leaves the field unset (promoting
  `operand.networkpolicy` to on-by-default; the gate drives only that default, generation reads
  only the field). The allocator policy it creates admits any source on the allocator's ports.
  NetworkPolicies are a union, so that policy voided the fence — the first smoke run proved it,
  with a probe pod reading `/scrape_configs` from outside the collector. The chart renders
  `spec.networkPolicy.enabled: false` on the cluster collector CR while its own policy is on; that
  is the only switch, and the operator copies it onto the generated TargetAllocator. Since ADR-0019
  the operator's policies are off on every collector CR by default, and this CR stays off while the
  fence renders even when a consumer turns them on. The operator does not delete an allocator policy
  it already created when the field flips, so clusters that ran chart 0.21–0.25 need the one-off
  cleanup in the chart README's 0.27.0 note before this fence holds.
- The **node allocator** stays masked (`allowInsecureAuthSecrets: false`). It selects every workload
  monitor in the cluster, and the node collectors run `hostNetwork`, so no pod-selector policy could
  fence it.

**mTLS is the correct end state, and every knob for it is exposed now.**
`collectors.<node|cluster>.targetAllocator.mtls` is rendered verbatim as `spec.targetAllocator.mtls`
(cert-manager, or bring-your-own certificates on operator ≥ 0.157). When `mtls.enabled` is true the
chart stops rendering `allowInsecureAuthSecrets` for that allocator (`lgtm.targetAllocator.secretTransport`),
so enabling mTLS alone never leaves the plain-HTTP path serving secrets too.

The smoke test now asserts that apiserver metrics actually arrive, not only that no error is logged.

## Alternatives considered

- **Own the control-plane ServiceMonitors in this chart, with `bearerTokenFile`.** Disable the kps
  apiserver/CoreDNS monitors (keeping kps's CoreDNS Service) and ship our own with the v89 shape; set
  `prometheus.serviceAccount.createTokenSecret: false`. No credential moves between pods and no
  long-lived token Secret is created. Rejected for now: every
  `kube-prometheus-stack.kubeApiServer.*` / `coreDns.serviceMonitor.*` setting would silently stop
  applying, and `bearerTokenFile` is a deprecated field kept alive by us rather than upstream.
- **mTLS as the default.** The right answer on security grounds. Rejected as a *default* because it
  needs certificates the chart cannot produce well: cert-manager is not a prerequisite of this chart,
  and Helm's `genCA` would issue new certificates on every render — every ArgoCD sync — while
  `lookup` returns nothing under ArgoCD. It is fully configurable instead, with an example values file.
- **`null` the kps `authorization` defaults from our `values.yaml`.** Would stop the token being sent
  to CoreDNS and let us drop the token Secret. Does not work: Helm does not apply a parent chart's
  own `null` to subchart defaults (verified on Helm 4.3; a user's `-f` file does work). Overriding with
  `false` does strip it, but only through a coalesce quirk that prints
  `cannot overwrite table with non table` on every render.
- **Enable `allowInsecureAuthSecrets` on both allocators.** Would also unmask workload monitors'
  credentials. Rejected: that hands every workload credential in the cluster to anything that can
  reach an unfenceable Service.

## Consequences

- Anything that can reach `otel-cluster-collector-targetallocator` and is not stopped by the
  NetworkPolicy can read `prom-stack-prometheus-token` from `/scrape_configs`. That token carries the
  kps Prometheus ClusterRole: cluster-wide `get`/`list`/`watch` on pods (full specs, env values
  included), services, endpoints, endpointslices, nodes and ingresses, plus `/metrics`. On CNIs that
  do not enforce NetworkPolicy the fence is inert. This is accepted as a stop-gap, and it is why mTLS
  is documented as the recommended setup.
- Disabling the operator's policies for the cluster collector drops two things beyond the
  allocator's allow-all ingress: the collector's own ingress policy (any source, its declared ports
  only; without it ingress is open), and the allocator's egress restriction to the apiserver
  endpoint IPs the operator discovers at startup. The chart cannot reproduce the latter at render
  time, and ADR-0019 found it unsafe to keep anyway (it never matches on Cilium and goes stale when
  control-plane IPs change), so the chart's policy is ingress-only.
- The real token is also sent, in cleartext, to CoreDNS, which does not need it. Users can set
  `kube-prometheus-stack.coreDns.serviceMonitor.authorization: null` in their own values.
- kube-prometheus-stack now renders a long-lived `kubernetes.io/service-account-token` Secret in the
  release namespace, readable by both allocators through the ADR-0014 Role.
- Workload monitors scraped by the node collectors that reference credentials still reach them as
  `<secret>` unless the node allocator runs mTLS. This is unchanged behaviour, now documented next to
  `collectors.targetAllocator.secretNamespaces`.
- Purely additive for existing values; no chart major.

## Confidence

High for the mechanism. The masking and its two escape hatches were read from the operator source
(`cmd/otel-allocator/internal/server/server.go`); `allowInsecureAuthSecrets` and the `mtls` block
(`enabled`, `useCertManager`, `tls.{certificateAuthorityCertificate,serverCertificate,clientCertificate}`)
were confirmed in the `OpenTelemetryCollector` CRD shipped by the pinned `opentelemetry-operator`
0.122.0 chart (operator 0.158.0). The collector's mTLS endpoint (`https://<ta-service>:443`) comes from
`internal/manifests/targetallocator/adapters/config_to_prom_config.go`. The kps change was read from
the 89.2.4 → 90.0.0 chart diff, and the failure is reproduced by the smoke test.

Medium for the NetworkPolicy's portability: kubelet probes and host-originated traffic are
CNI-dependent under an ingress policy. The smoke run on kind is the first check; clusters whose CNI
blocks probes can disable the policy or extend `extraIngress`.
