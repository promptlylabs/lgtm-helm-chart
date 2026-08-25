# lgtm

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/promptlylabs)](https://artifacthub.io/packages/search?repo=promptlylabs)

An opinionated observability stack in one Helm release: **L**oki, **G**rafana, **T**empo, Prometheus (**M**etrics) and **P**yroscope, all in single-binary mode, collected OpenTelemetry-natively by operator-managed collectors — with correlated datasources and OTel-native dashboards included.

```
                        ┌────────────────────────────────────────────┐
   apps (OTLP) ──────►  │ node collector (DaemonSet)                 │
   app ServiceMonitors  │  otlp · hostmetrics · kubeletstats ·       │
   (scraped per-node)   │  filelog · prometheus (target allocator)   │
                        └──────┬──────────────┬──────────────┬───────┘
   K8s events / cluster ┌──────┴──────┐┌──────┴──────┐┌──────┴──────┐┌─────────────┐
   metrics / apiserver  │ metrics     ││ logs        ││ traces      ││ profiles    │
   via cluster collector│ ▼           ││ ▼           ││ ▼           ││ (SDK push)  │
   browser telemetry    │ Prometheus  ││ Loki :3100  ││ Tempo :4317 ││ Pyroscope   │
   via faro collector   │ OTLP ingest ││ OTLP ingest ││ OTLP gRPC   ││ :4040       │
                        └──────┬──────┘└──────┬──────┘└──────┬──────┘└──────┬──────┘
                               └───────┬──────┴──────────────┴──────────────┘
                                       ▼
                          Grafana (correlated datasources,
                        exemplars → traces → logs → profiles)
```

The architecture is OTLP-push with a scrape-less, storage-only Prometheus: collectors own all collection, node-exporter/kube-state-metrics/Alertmanager are disabled, and the shipped dashboards use OTel metric names. Profiles are the one signal that bypasses the collectors — apps push them straight to Pyroscope with its SDKs (or enable `pyroscope.alloy` to scrape pprof endpoints). The reasoning behind every major choice is recorded as ADRs in [`docs/adrs/`](https://github.com/promptlylabs/lgtm-helm-chart/tree/main/docs/adrs).

## Components

| Component | Chart | Mode |
|---|---|---|
| kube-prometheus-stack | [prometheus-community](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) | Prometheus single replica, OTLP-only, scraping disabled |
| grafana | [grafana-community](https://github.com/grafana-community/helm-charts/tree/main/charts/grafana) | single replica, sidecar provisioning |
| loki | [grafana-community](https://github.com/grafana-community/helm-charts/tree/main/charts/loki) | Monolithic, gateway + caches disabled, filesystem storage |
| tempo | [grafana-community](https://github.com/grafana-community/helm-charts/tree/main/charts/tempo) | single binary, metrics-generator → Prometheus |
| pyroscope | [grafana](https://github.com/grafana/pyroscope/tree/main/operations/pyroscope/helm/pyroscope) | single binary, v2 storage |
| opentelemetry-operator | [open-telemetry](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-operator) | manages the 3 collector CRs below |

Plus, owned by this chart: **node**, **cluster** and (optional) **faro** OpenTelemetryCollector CRs, a Grafana datasources ConfigMap with full trace/log/metric/profile correlations, and fourteen dashboards: OTel-native infrastructure views (home, host metrics, cluster, namespace, container, storage, network, Karpenter/NAP) plus first-party component self-observability dashboards (Loki, Prometheus, OTel Collector, Grafana, Tempo, Pyroscope). Each dashboard is provisioned only when the component it observes is enabled (the `otel-*` views follow `collectors.enabled`; `home` is always shipped). The component dashboards read self-metrics that are only collected with in-cluster self-monitoring on — `lgtm.metaMonitoring.enabled=false`, the default (see [ADR-0012](../../docs/adrs/0012-first-party-component-dashboards.md)). On top of those, a baseline pack of **Grafana-managed alert rules** for the same components, gated the same way (see [Alerting](#alerting) and [ADR-0015](../../docs/adrs/0015-grafana-managed-alerting.md)).

## Install

```bash
helm repo add promptlylabs https://promptlylabs.github.io/lgtm-helm-chart
```

**Plain Helm — first install is two-phase.** The collector CRs need the OTel operator's admission webhook, which isn't ready mid-install:

```bash
helm install lgtm promptlylabs/lgtm -n observability --create-namespace \
  --set collectors.enabled=false
helm upgrade lgtm promptlylabs/lgtm -n observability \
  --reuse-values --set collectors.enabled=true
```

(Re-running `helm upgrade --install` after a failed single-shot install works too.)

**ArgoCD** converges in one Application — but two settings are required, see [`examples/argocd-application.yaml`](examples/argocd-application.yaml):

- `ServerSideApply=true` — kube-prometheus-stack CRDs are 600–830KB, over the client-side-apply annotation limit.
- `retry` — the first sync's collector CRs fail until the operator webhook is up; retries converge.

## Configuration

Sub-chart values pass through under their top-level key (`loki.*`, `grafana.*`, `kube-prometheus-stack.*`, …) — see each upstream chart's documentation. The umbrella's own keys:

> **Breaking in 0.12.0** (ADR-0013) — three changes:
>
> - The shared `collectors.priorityClassName` key is replaced by per-collector `collectors.node.priorityClassName` / `.cluster.` / `.faro.`, and the node and cluster collectors now default to `system-node-critical` / `system-cluster-critical`. The values schema rejects the old key, so an upgrade that still sets it fails immediately rather than silently ignoring it.
> - The node collector's persistent queue moved from `hostPath` to `emptyDir` by default. **This affects every install running `collectors.persistentQueue.enabled: true`, whether or not you ever set `collectors.persistentQueue.node.hostPath`** — the key has a working default (`/var/lib/otelcol-queue`), so hostPath is what you were already getting, and [`values-baremetal.yaml`](examples/values-baremetal.yaml) enables the queue without naming it. This is the one change here that does *not* fail loudly. Two consequences on upgrade:
>   - The queue silently moves to an `emptyDir`. Add `collectors.persistentQueue.node.backend: hostPath` to keep the previous behaviour.
>   - Anything still queued in the old directory is abandoned — undelivered batches there are never drained — and `/var/lib/otelcol-queue` is **left behind on every node**, consuming disk until you remove it. Once you're satisfied nothing in it is needed, clean it up across the fleet (e.g. `rm -rf /var/lib/otelcol-queue`); on SELinux hosts also drop any `semanage fcontext` rule you added for it.
> - The `queue-permissions` chown initContainer no longer renders by default on either collector (`podSecurityContext.fsGroup` replaces it). **If the cluster collector's queue PVC is on file/NFS-backed storage** (EFS, Azure Files, `nfs-subdir-provisioner` — any CSI driver that doesn't apply `fsGroup`), set `collectors.persistentQueue.cluster.chownInitContainer: true` to restore it, or the collector will not be able to write the queue directory.

| Key | Default | Purpose |
|---|---|---|
| `lgtm.clusterName` | `""` | Added as the `cluster` resource attribute on all telemetry |
| `lgtm.clusterDomain` | `cluster.local` | Cluster DNS domain for computed endpoints |
| `lgtm.endpoints.*` | `""` (computed) | Override per-component endpoints (external Prometheus etc.) |
| `lgtm.datasources.enabled` | `true` | Provision the correlated Grafana datasources |
| `lgtm.dashboards.enabled` | `true` | Provision the shipped dashboards (each gated on the component it observes) |
| `lgtm.dashboards.folder` | `Platform` | Grafana folder for the shipped dashboards |
| `lgtm.dashboards.exclude` | `[]` | Skip dashboards by basename (e.g. `[loki, prometheus, otel-collector, grafana, tempo, pyroscope, otel-karpenter-nap]`) |
| `lgtm.alerting.enabled` | `true` | Provision the shipped Grafana alert rules (each gated on the component it watches) |
| `lgtm.alerting.folder` | `Platform` | Grafana folder for the shipped rule groups |
| `lgtm.alerting.interval` | `1m` | Evaluation interval for the shipped rule groups |
| `lgtm.alerting.datasourceUid` | `prometheus` | Datasource the shipped rules query |
| `lgtm.alerting.commonLabels` | `{}` | Labels merged onto every shipped rule, for routing (e.g. `{team: platform}`) |
| `lgtm.alerting.exclude` | `[]` | Skip rule packs by basename (`[otel-collector, loki, prometheus, tempo]`) |
| `lgtm.alerting.contactPoints` | `[]` | Contact points, in Grafana provisioning format — see [Alerting](#alerting) |
| `lgtm.alerting.policies` | `[]` | Notification policies. Only provisioned when `contactPoints` is also set |
| `lgtm.alerting.templates` | `[]` | Notification templates, in Grafana provisioning format |
| `lgtm.metaMonitoring.enabled` | `false` | Reserve the observability stack's own `scope: observability` ServiceMonitors for a separate meta-monitoring stack; default `false` scrapes them in-cluster |
| `collectors.enabled` | `true` | Master switch for all collector CRs |
| `collectors.image` | `""` | Override the collector image (node + cluster) |
| `collectors.resourceDetection.detectors` | `[]` | resourcedetection processor detectors (e.g. `[azure]`) |
| `collectors.persistentQueue.enabled` | `false` | Back exporter sending queues with a `file_storage` extension on durable storage (node → emptyDir, cluster → PVC) so queued batches survive a restart. See [Bare-metal / hostNetwork](#bare-metal--hostnetwork) |
| `collectors.persistentQueue.node.backend` | `emptyDir` | What backs the DaemonSet queue: `emptyDir` (no chown initContainer, SELinux-safe, bounded by `sizeLimit`) or `hostPath` (also survives pod recreation). See [Bare-metal / hostNetwork](#bare-metal--hostnetwork) |
| `collectors.persistentQueue.cluster.chownInitContainer` | `false` | Run the root chown initContainer on the cluster collector. Needed only on storage classes whose CSI driver does not apply `fsGroup` (file/NFS-backed: EFS, Azure Files, `nfs-subdir-provisioner`) |
| `collectors.<node\|cluster\|faro>.priorityClassName` | `system-node-critical` / `system-cluster-critical` / `""` | PriorityClass per collector. The two `system-*` classes are built into every cluster and are what makes kubelet keep admitting the pod under `DiskPressure` — set to `""` to opt out |
| `collectors.<node\|cluster\|faro>.podSecurityContext` | `fsGroup: 10001` (node, cluster) / `{}` (faro) | Pod security context. `fsGroup` is what makes the queue volume writable; add `seLinuxOptions` here on Enforcing clusters — see [SELinux-enforcing clusters](#selinux-enforcing-clusters) |
| `collectors.<node\|cluster\|faro>.securityContext` | `{}` | Container security context for the `otc-container` |
| `collectors.targetAllocator.secretNamespaces` | `[]` | Extra namespaces the target allocators may read Secrets in, on top of the release namespace. Needed when a ServiceMonitor/PodMonitor **outside** the release namespace references a Secret (`tlsConfig`, `basicAuth`, `authorization`) — see [Target allocator](#target-allocator) |
| `collectors.<node\|cluster>.targetAllocator.resources` | `64Mi` limit / `5m`+`32Mi` requests | Resources for the target-allocator Deployment. **The default suits small target sets only** — see [Target allocator](#target-allocator) |
| `collectors.node.*` | enabled | DaemonSet collector: resources, tolerations |
| `collectors.node.collectAllNetworkInterfaces` | `false` | Collect node network metrics from **all** NICs, not just the default — needed on multi-NIC bare-metal nodes with no default interface (adds an `interface` attribute). See [Bare-metal / hostNetwork](#bare-metal--hostnetwork) |
| `collectors.node.kubeletInsecureSkipVerify` | `true` | Skip TLS verification when the node collector scrapes the kubelet on `:10250`. Set `false` only where kubelet serving certs are signed by the cluster CA — see [Kubelet TLS verification](#kubelet-tls-verification) |
| `collectors.node.internalMetricsPort` | `8888` | Host port for the node collector's own internal-telemetry metrics endpoint (the DaemonSet is hostNetwork). Move it if `:8888` is taken on the host |
| `collectors.cluster.*` | enabled | Cluster collector: resources |
| `collectors.faro.*` | disabled | Browser telemetry: requires `image` (contrib distro) + `corsAllowedOrigins` |
| `thanos.enabled` | `false` | Umbrella-owned Thanos query stack (Query/Store Gateway/Compactor) — see [Long-term metrics (Thanos)](#long-term-metrics-thanos) |
| `thanos.objstore.existingSecret` | `""` | Existing Secret holding the Thanos `objstore.yml` (shared by Store Gateway + Compactor) |
| `thanos.objstore.caCert.existingSecret` | `""` | Existing Secret with a private/custom CA bundle for the object-store TLS endpoint — mounted read-only into Store Gateway + Compactor with `SSL_CERT_FILE` pointed at it, so an on-prem S3 verifies without `insecure_skip_verify` |

The Thanos **sidecar** itself is a `kube-prometheus-stack.*` pass-through (not an umbrella key); the [`values-thanos.yaml`](examples/values-thanos.yaml) overlay wires both.

### Shipping your own telemetry and dashboards

- **Apps** send OTLP to `otel-node-collector-collector.<namespace>.svc:4317` (gRPC) or `:4318` (HTTP). The operator service routes to the same-node collector pod.
- **ServiceMonitors/PodMonitors** are scraped automatically, from any namespace, with no labels needed. Label `opentelemetry.io/scope: cluster` routes a monitor to the cluster collector instead. Label `opentelemetry.io/scope: observability` marks the observability stack's own monitors — by default they're scraped in-cluster like everything else; set `lgtm.metaMonitoring.enabled=true` to reserve them for a separate meta-monitoring stack (see [`examples/values-meta-monitoring.yaml`](examples/values-meta-monitoring.yaml)).
- **Dashboards**: any ConfigMap labelled `grafana_dashboard: "1"` in any namespace (folder via the `grafana_folder` annotation). Datasources and Grafana alert rules work the same with `grafana_datasource` / `grafana_alert` — note alert rules name their folder *inside* the provisioning file, not in an annotation. See [Alerting](#alerting).
- **PromQL**: OTel metric names *and label names* are preserved 1:1 — quote both, e.g. `{"k8s.pod.cpu.usage", "k8s.namespace.name"="default"}` and `sum by ("k8s.node.name") (...)`. The underscored spelling (`k8s_namespace_name`) is **Loki's** — Loki's OTLP ingestion does sanitise attribute names, so it is right there and wrong here. Getting it wrong in a Prometheus query does not error: an underscored name is a legal label name that matches nothing, so you get an empty result rather than a complaint. `make lint` checks the shipped rules and dashboards for this.

### Target allocator

Each of the node and cluster collectors gets a **target allocator** — a separate Deployment the OTel operator creates, which watches ServiceMonitors/PodMonitors and hands the resulting scrape targets to the collector. Two things about it are worth knowing before you run this in anger.

**It reads Secrets, and needs RBAC for them.** With `prometheusCR` enabled the allocator resolves each selected monitor's `tlsConfig` / `basicAuth` / `authorization` references *itself*, so it needs to read the Secrets they point at. It does that two ways: a metadata **informer** over Secrets (for change detection) and a direct `get` per reference. The informer is the one with teeth — without `list`/`watch` its cache never syncs and the allocator **exits**, crashlooping every few minutes with `secrets is forbidden` and `Unable to sync caches`.

The chart grants this with a namespaced `Role` + `RoleBinding` in the release namespace rather than a rule on the shared ClusterRole, because that is exactly the scope the informer uses: the operator scopes it to the allocator's own namespace unless told otherwise. `list`/`watch` on Secrets cannot be narrowed with `resourceNames`, so a ClusterRole rule would mean cluster-wide Secret read for both allocators to satisfy an informer that only ever watches one namespace.

If a monitor in **another** namespace references a Secret, list that namespace in `collectors.targetAllocator.secretNamespaces`. That widens both sides together — the CRs' `prometheusCR.secretNamespaces` and the Roles — which is the point of the single key: if the informer scope and the RBAC ever disagreed, the allocator would crashloop on a cache it is not allowed to sync. The release namespace is always included, and the listed namespaces must already exist. Leave it empty and a secret-referencing monitor elsewhere is simply skipped, with a `skipping object` warning in the allocator log and no scrape for that endpoint — degraded, but not fatal.

**Size it for your target set.** `collectors.<node|cluster>.targetAllocator.resources` defaults to a `64Mi` limit with `5m`/`32Mi` requests, and allocator memory tracks the number of discovered target groups, not telemetry volume. That default is adequate **only for small target sets**. A real datapoint from a modest 3-node production cluster: the *cluster* allocator — which selects only the `scope: cluster` monitors, so the smallest target set the chart produces — sits at **52Mi against the 64Mi limit, 81% utilisation with no headroom**; the *node* allocator on the same cluster, which selects every other monitor (19 target groups), **OOMKills at 64Mi outright** (`exitCode: 137`). If you run more than a handful of monitors, raise `collectors.node.targetAllocator.resources.limits.memory` — `128Mi` is a reasonable starting point — and read the [Operations](#operations) note on why an OOMKilling allocator is easy to miss.

### Alerting

Alerting is **Grafana-managed** (ADR-0015): Alertmanager is disabled, and rules, contact points and notification policies are provisioned from ConfigMaps labelled `grafana_alert: "1"`, from any namespace. The chart ships a baseline rule pack for its own components, and no contact points — where alerts *go* is site-specific.

**The shipped rules** live in `alerts/`, one pack per component, each gated on that component being enabled exactly like the dashboards: `otel-collector`, `loki`, `prometheus`, `tempo`. They watch ingest and query error rates, queue and WAL saturation, compaction health, and — the one that prompted the pack — **Target Allocator restarts**. Each allocator is a separate Deployment whose health is not reflected in the parent `OpenTelemetryCollector` CR status, so an ArgoCD Application reports `Healthy` right through an allocator crashloop; we have seen that hide one for 8 days and ~1800 restarts while every ServiceMonitor in the cluster flapped in and out of the scrape set (see [Target allocator](#target-allocator) and [Operations](#operations)).

Two things to know about them:

- They read the stack's **own self-metrics**, which only exist with in-cluster self-monitoring on — `lgtm.metaMonitoring.enabled=false`, the default. With a separate meta-monitoring stack these rules evaluate to no data; every rate-based rule uses `noDataState: OK` so that stays quiet rather than firing, and the per-component "not reporting" rules are the ones that would tell you.
- They are **on by default and notify nothing** until you add a contact point. Firing rules are visible in Grafana's Alerting UI from the first install; nothing is sent anywhere until `lgtm.alerting.contactPoints` and `lgtm.alerting.policies` are set.

Drop individual packs with `lgtm.alerting.exclude` (by basename), or turn the whole thing off with `lgtm.alerting.enabled=false`. Tag every shipped rule for routing with `lgtm.alerting.commonLabels`.

**Contact points and policies** pass straight through to Grafana's [file-provisioning format](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/):

```yaml
lgtm:
  alerting:
    commonLabels:
      team: platform
    contactPoints:
      - orgId: 1
        name: platform-oncall
        receivers:
          - uid: platform-oncall-email
            type: email
            settings:
              addresses: oncall@example.com
    policies:
      - orgId: 1
        receiver: platform-oncall
        group_by: [alertname, component]
```

Policies are only provisioned when `contactPoints` is also non-empty: a policy routing to a receiver Grafana has never seen fails provisioning outright and takes the rest of the file with it.

Writing your own rules: the shipped ones follow the convention that **a positive PromQL result means bad**, so every rule is a `gt` threshold and reads the same in the file as it does in the UI. For "should be present but isn't", `absent()` gives the same polarity.

> **A malformed rule ConfigMap stops Grafana from starting.** Grafana treats alerting provisioning as fatal at boot: one invalid rule anywhere — in *any* namespace, since the sidecar watches all of them — and Grafana exits, taking dashboards and datasources down with it. It is not a per-file skip, and the error only appears in the Grafana container log (`failed to start *ngalert.AlertNG`). Note the asymmetry: a bad file added while Grafana is *running* is rejected by the hot-reload endpoint and is harmless; the same file is fatal on the next restart. Two constraints worth knowing because Grafana enforces them silently until then: rule **uids are capped at 40 characters**, and each uid must be unique. `make validate-alerts` checks both for the shipped packs.

### Alerting HA (more than one Grafana replica)

Grafana-managed alerting means each Grafana replica runs its own Alertmanager. The chart wires them into a gossip ring unconditionally — `grafana.headlessService` plus `grafana.ini`'s `[unified_alerting]` `ha_listen_address` / `ha_advertise_address` / `ha_peers`, pointed at the `grafana-headless` Service on `:9094`. At the default single replica that is one peer gossiping with itself, i.e. a no-op; without it, scaling to two replicas would silently notify twice for every alert. (`POD_IP` needs no wiring: the Grafana chart already injects it, and `$__env{POD_IP}` is expanded by Grafana's own config parser.)

**The gossip ring is necessary but not sufficient.** Grafana's HA alerting also requires every replica to share **one database**, and this chart defaults to ephemeral per-pod SQLite — each replica would otherwise keep its own alert state, silences and dashboards. So `grafana.replicas > 1` needs an external MySQL/PostgreSQL as well; [`values-azure.yaml`](examples/values-azure.yaml) shows the PostgreSQL pattern.

The chart refuses to render rather than ship a stack that double-notifies: raising `grafana.replicas` above 1 fails with a message unless both halves are in place. It accepts a database configured in `grafana.ini`, via `GF_DATABASE_TYPE`/`GF_DATABASE_URL` in `grafana.env`, or through any `envFrom*` source it cannot introspect.

### Storage

Defaults are PVC-backed local storage so the chart installs on any cluster with a default StorageClass (Prometheus 20Gi, Tempo 15Gi, Loki 10Gi, Pyroscope 10Gi). For Loki/Tempo on each cloud's blob storage with keyless workload identity, start from the matching overlay: [`values-azure.yaml`](examples/values-azure.yaml) (Blob Storage + Workload Identity, plus the full Grafana PostgreSQL + Entra ID pattern), [`values-aws.yaml`](examples/values-aws.yaml) (S3 + IRSA), [`values-gcp.yaml`](examples/values-gcp.yaml) (GCS + GKE Workload Identity). Bare-metal Talos clusters keep the local-storage defaults — [`values-talos.yaml`](examples/values-talos.yaml) covers the Talos-specific requirements (privileged Pod Security label for the node collector, control-plane tolerations).

### Bare-metal / hostNetwork

The node collector is a `hostNetwork` DaemonSet (ADR-0005). On multi-NIC bare-metal clusters (RKE2 and similar on-prem distros) two knobs — both **off by default** so cloud/single-NIC installs are unchanged — harden it (ADR-0011). The [`values-baremetal.yaml`](examples/values-baremetal.yaml) overlay turns them on:

- **`collectors.node.collectAllNetworkInterfaces`** — when a node has several NICs and no default interface, the kubelet reports an empty interface name and the kubeletstats receiver emits **no** `k8s.node.network.io` at all ([contrib #40915](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/40915)). Setting this to `true` collects from every interface and adds an `interface` resource attribute — one series per node NIC, so cardinality stays bounded. The shipped **OTel Network** dashboard aggregates node network metrics with `sum`, so it renders unchanged with the extra label.
- **`collectors.node.internalMetricsPort`** — because the DaemonSet shares the host network, the collector's own internal-telemetry endpoint binds a host port. On distros where `:8888` is already bound the collector crashes with `bind: address already in use`; set a free port. It is rendered via `service.telemetry.metrics.readers` (the `service.telemetry.metrics.address` shortcut was removed in collector v0.111+). **Caveat:** nothing in this chart scrapes the internal-telemetry endpoint by default. If you add a scrape for it — or enable the operator self-monitor via `spec.observability.metrics`, which targets `8888` — point it at the port you set here.
- **`collectors.persistentQueue.enabled`** — by default the exporter sending queues are in-memory (ADR-0009), so a collector restart during a backend-down window drops queued batches. Setting this to `true` backs each queue with a `file_storage` extension on durable storage — an `emptyDir` for the DaemonSet, a per-replica PVC for the StatefulSet (`collectors.persistentQueue.cluster.size` / `.storageClassName`). Neither normally needs a `chown` initContainer: `podSecurityContext.fsGroup` makes kubelet set ownership for the collector user (UID 10001), which matters because the collector image is distroless. Useful anywhere, but most valuable on on-prem clusters with a less reliable link to the backends.
- **`collectors.persistentQueue.node.backend`** — `emptyDir` (default) or `hostPath` (ADR-0013). `emptyDir` survives container restarts, which is the case the durable queue exists for; kubelet applies `fsGroup` to it and the container runtime labels it with the pod's own SELinux category, so it needs no initContainer and works unchanged on Enforcing nodes. It also counts toward the pod's ephemeral storage, so kubelet can account for and bound it (`collectors.persistentQueue.node.sizeLimit`, default `2Gi` — kubelet evicts the pod if it is exceeded, so size it for your worst-case backend-down window) rather than the queue growing invisibly on the host. Note it lives under the kubelet root directory (`/var/lib/kubelet` by default), which on a stock node layout is the **same filesystem** as a `/var/lib` hostPath — it only lands elsewhere if that directory is a separate mount. Switch to `hostPath` (`collectors.persistentQueue.node.hostPath`) only if the queue must also survive **pod** recreation, e.g. a chart upgrade: `fsGroup` is not applied to hostPath volumes, so that path pulls in a root `chown` initContainer (`collectors.persistentQueue.initImage`), and on SELinux-enforcing nodes the host directory must be relabelled first — see [SELinux-enforcing clusters](#selinux-enforcing-clusters).
- **`collectors.persistentQueue.cluster.chownInitContainer`** — `false` by default, because kubelet applies `fsGroup` to PVCs on block storage. Set it to `true` for storage classes whose CSI driver does **not** apply `fsGroup`: file/NFS-backed drivers (EFS, Azure Files, `nfs-subdir-provisioner`) declare `CSIDriver.fsGroupPolicy: None`, and the default `ReadWriteOnceWithFSType` policy skips volumes with no `fsType`. Symptom if you need it and don't set it: the cluster collector starts but cannot write `/var/lib/otelcol/queue`, which stays root-owned.

Two related notes on the **PriorityClasses** (`collectors.node.priorityClassName` = `system-node-critical`, `collectors.cluster.priorityClassName` = `system-cluster-critical` by default): kubelet's admission handler rejects non-critical pods while a node carries the `DiskPressure` condition, and "critical" means exactly one of those two built-in classes — so the defaults are what keep the collectors running through the incidents you most want telemetry for. Be aware they also let the collector **preempt** lower-priority workloads on a full node. The target-allocator Deployments are separate pods and the operator's CRD exposes no `priorityClassName` for them, so they remain evictable.

### Kubelet TLS verification

The node collector's `kubeletstats` receiver scrapes each kubelet over HTTPS on `:10250` with `auth_type: serviceAccount`, and the chart sets `insecure_skip_verify: true` on it by default (`collectors.node.kubeletInsecureSkipVerify`). The reason is that most kubelets serve a **self-signed** serving certificate, which no CA available to the pod can verify. Because this receiver is the chart's only source of kubelet metrics — the kubelet ServiceMonitor is disabled (ADR-0005) — verifying against a self-signed cert would fail every scrape with `x509: certificate signed by unknown authority` and take `k8s.pod.*`, `k8s.node.*` and `container.*` with it. The default is therefore left on, and this knob is a no-op for installs that don't touch it.

Set it to `false` when kubelet serving certificates are signed by the **cluster CA**. `auth_type: serviceAccount` already makes the receiver verify against the pod's projected service-account bundle (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`) — the same CA — so verification then succeeds with nothing else to configure in this chart. Two things have to be true in the cluster first:

- **Kubelets must request serving certificates from the cluster CA** instead of self-signing. On [Talos](https://www.talos.dev/), set `machine.kubelet.extraArgs.rotate-server-certificates: true`; on kubeadm clusters, `serverTLSBootstrap: true` in the `KubeletConfiguration`.
- **Something must approve the resulting CSRs.** `kube-controller-manager` never auto-approves `kubernetes.io/kubelet-serving` requests, so they need an approver such as [kubelet-serving-cert-approver](https://github.com/alex1989hu/kubelet-serving-cert-approver) or [kubelet-csr-approver](https://github.com/postfinance/kubelet-csr-approver). Without one the CSRs sit `Pending`, the kubelet keeps its self-signed certificate, and scrapes start failing the moment you turn the skip off.

Check both before flipping it — `kubectl get csr` should show `kubernetes.io/kubelet-serving` requests in `Approved,Issued`, not `Pending`. If node metrics disappear after the change, the node collector logs the `x509` error per scrape; setting the value back to `true` restores them immediately.

### SELinux-enforcing clusters

On distros that run SELinux in **Enforcing** mode (RKE2 on Rocky/RHEL/AlmaLinux and similar), the node collector needs one extra setting. Start from [`values-selinux.yaml`](examples/values-selinux.yaml), which layers on top of any environment overlay:

```bash
helm upgrade lgtm . -f examples/values-baremetal.yaml -f examples/values-selinux.yaml
```

**Container logs.** The `filelog` receiver reads `/var/log/pods`, which is labelled `container_log_t`. A confined `container_t` process cannot read it, so the collector starts, reports healthy, and silently ships no container logs while the node's audit log fills with:

```
avc: denied { read } comm="otelcol-k8s" name="pods"
  scontext=system_u:system_r:container_t:s0:c... tcontext=system_u:object_r:container_log_t:s0 tclass=dir
```

Relabelling `/var/log/pods` is **not** a fix — kubelet and containerd both expect `container_log_t` there, and policy reloads/`restorecon` will revert it. Run the collector in the unconfined `spc_t` domain instead, the convention for log collectors on SELinux systems:

```yaml
collectors:
  node:
    podSecurityContext:
      fsGroup: 10001          # keep this — it is what makes the queue volume writable
      seLinuxOptions:
        type: spc_t
```

Set it at the **pod** level so it covers the `otc-container` and any initContainer. Note that `spc_t` effectively removes SELinux confinement for this pod; scope it to the node collector, which is the only one reading host paths. `collectors.<collector>.securityContext` takes the same `seLinuxOptions` at container level if you want narrower scope.

**The persistent queue needs nothing extra** on the default `emptyDir` backing — kubelet applies `fsGroup` and the runtime labels the volume with the pod's own MCS category. If you opt into `collectors.persistentQueue.node.backend=hostPath`, relabel the directory on every node first:

```bash
semanage fcontext -a -t container_file_t '/var/lib/otelcol-queue(/.*)?'
restorecon -Rv /var/lib/otelcol-queue
```

Without it, the `chown` initContainer that the hostPath backing requires is denied `setattr` on `container_var_lib_t` and the DaemonSet goes into `CrashLoopBackOff` — it runs as root, so this is SELinux rather than file permissions:

```
avc: denied { setattr } scontext=...:container_t tcontext=...:container_var_lib_t
```

Nodes left in Permissive mode will mask all of the above until they are rebooted or set back to Enforcing.

### Long-term metrics (Thanos)

Prometheus is storage-only with local retention (ADR-0005), so metrics don't survive node loss and aren't queryable beyond retention. Enabling Thanos (ADR-0010, **off by default**) fixes both: the Prometheus Operator injects a **sidecar** that uploads completed 2h TSDB blocks to S3-compatible object storage, and this chart's own **Query + Store Gateway + Compactor** make those blocks queryable in Grafana beyond local retention. Grafana's Prometheus datasource is repointed to Thanos Query automatically — dashboards and correlations are unchanged (the `prometheus` datasource UID is kept).

Start from [`values-thanos.yaml`](examples/values-thanos.yaml) (generic S3 — works with Cloudflare R2, AWS S3, MinIO). It enables the sidecar (`kube-prometheus-stack.prometheus.prometheusSpec.thanos` + `thanosService`) and the umbrella `thanos.*` stack, both referencing one **existing** Secret you provide out of band (e.g. External Secrets Operator): a `thanos-objstore` Secret whose `objstore.yml` key holds the Thanos object-store config. Credentials never go in values.

Object-store notes: `endpoint` is the host only (no scheme, no bucket), `bucket_lookup_type: auto` gives path-style for non-AWS endpoints, and keep `signature_version2: false` (S3 SigV4). For R2 the endpoint is `<account-id>.r2.cloudflarestorage.com` (or `<account-id>.eu.r2.cloudflarestorage.com` for the EU jurisdiction) with `region: auto`.

Private-CA S3 (e.g. an on-prem Huawei OceanStor whose cert is signed by a private CA): set `thanos.objstore.caCert.existingSecret` to a Secret holding the CA bundle — it's mounted read-only into Store Gateway + Compactor and `SSL_CERT_FILE` is pointed at it, so TLS verifies without `http_config.tls_config.insecure_skip_verify`. Cover the sidecar half the same way via `kube-prometheus-stack.prometheus.prometheusSpec.volumes` + `prometheusSpec.thanos.volumeMounts` + an `objstore.yml` `ca_file` (see [`values-thanos.yaml`](examples/values-thanos.yaml)). For anything the built-in knobs don't cover, `thanos.extraVolumes` / `thanos.extraVolumeMounts` / `thanos.extraEnv` are applied to all three components.

Keep local `retention` at least a few hours so blocks upload before eviction — the default 7d is fine, 24h is safe. With sidecar compaction disabled, don't set `retentionSize` so tight that a 2h block is evicted before it uploads (that gaps the bucket): prefer time-based retention. The **Compactor is a singleton** — it compacts, downsamples and enforces the bucket's retention; without it the bucket grows forever.

### Renaming and relocating components

The chart computes cross-component endpoints from each sub-chart's `fullnameOverride` and the release namespace. Two values are **literal** and must be kept in sync manually if you rename Prometheus, relocate components to other namespaces (`namespaceOverride` — supported by kube-prometheus-stack, grafana, loki and opentelemetry-operator only), or point at external ones:

- `tempo.tempo.metricsGenerator.remoteWriteUrl` (and `…metricsGenerator.storage.remote_write[].url`)
- `loki.singleBinary.extraEnv` → `OTEL_EXPORTER_OTLP_ENDPOINT`

plus the computed ones via `lgtm.endpoints.*`.

### Clusters with existing operators

- **prometheus-operator already installed**: set `kube-prometheus-stack.crds.enabled=false` and disable the in-chart operator (`kube-prometheus-stack.prometheusOperator.enabled=false`), or disable the whole dependency with `kube-prometheus-stack.enabled=false`.
- **OTel operator already installed**: set `opentelemetry-operator.enabled=false` — the collector CRs keep working against the existing operator (CRDs must be v1beta1-capable).

## Operations

- **Footprint**: the default install requests ≈0.5 CPU / 3.5Gi memory (memory limits total ≈7Gi). Every workload ships requests and memory limits; CPU limits are intentionally unset to avoid throttling.
- **Watch the target allocators, not just the collectors**: each allocator is a *separate* Deployment, and its health is **not** reflected in the parent `OpenTelemetryCollector` CR status — so an ArgoCD Application reports `Healthy` right through an allocator crashloop. We have seen this hide a node-allocator crashloop for 8 days (1839 restarts) while every ServiceMonitor in the cluster silently flapped in and out of the scrape set. There is no liveness probe that would have caught it either; the signal is the restart count. Check it directly with `kubectl -n observability get pods -l app.kubernetes.io/component=opentelemetry-targetallocator`. **The chart now alerts on this by default** — the `otel-collector` rule pack fires when an allocator restarts more than twice in an hour, off `k8s.container.restarts` from the cluster collector's `k8s_cluster` receiver (see [Alerting](#alerting)).
- **Cluster prerequisites**: a default StorageClass must exist — Prometheus/Loki/Tempo/Pyroscope PVCs sit Pending forever without one (`kubectl get storageclass`).
- **Data and uninstall**: `helm uninstall` keeps the data PVCs (Loki's StatefulSet auto-delete is explicitly disabled in the defaults) and keeps the CRDs — both are standard Helm behavior. A reinstall into the same namespace re-adopts the existing data. To wipe everything: uninstall, then delete the PVCs in the namespace and the `monitoring.coreos.com`/`opentelemetry.io` CRDs.
- **Grafana state is ephemeral by default** (SQLite in the pod, persistence off): everything provisioned by ConfigMaps — dashboards, datasources, alert rules — reappears after a restart, but content created *in the UI* (dashboards, contact points, silences) is lost. For durable UI state use an external database (see the azure example) or enable `grafana.persistence`.
- **Alerting**: Alertmanager is disabled; alerting is Grafana-managed. The chart ships a baseline rule pack for its own components and no contact points — see [Alerting](#alerting). Your own rules and contact points go in ConfigMaps labelled `grafana_alert: "1"` (Grafana alerting provisioning format) — with the ephemeral-state caveat above, never create them only in the UI.
- **Scaling**: the single-binary defaults are deliberate (see ADR-0004). Loki with filesystem storage is hard-limited to 1 replica — moving to object storage (cloud examples) is the prerequisite for scaling any of Loki/Tempo, and Prometheus HA is out of scope for this chart's defaults. Durable, long-term-queryable metrics are available separately via the optional Thanos sidecar + query stack (see [Long-term metrics (Thanos)](#long-term-metrics-thanos)).

## Development

Chart defaults live in `values.d/` fragments — edit those, then `make values` to regenerate `values.yaml` (CI rejects stale files). `make deps lint template kubeconform` runs the full local validation. Dashboards are plain JSON under `dashboards/`; each file becomes one ConfigMap, gated on its component in `templates/grafana/dashboards.yaml` (the `$gate` map). Alert rules follow the same shape under `alerts/`, gated in `templates/grafana/alerting.yaml` — except that those files **are** rendered through `tpl`, so they can call the shared `lgtm.alerting.query` helper for the A/B/C `data[]` triple, and any Grafana templating in them has to be escaped from Helm (`` {{ `{{ $labels.pod }}` }} ``). `make validate-alerts` renders and checks them.

## License

Apache-2.0 — see [LICENSE](https://github.com/promptlylabs/lgtm-helm-chart/blob/main/LICENSE).
