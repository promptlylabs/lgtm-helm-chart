# lgtm-helm-chart

[![Release Charts](https://github.com/promptlylabs/lgtm-helm-chart/actions/workflows/release.yaml/badge.svg)](https://github.com/promptlylabs/lgtm-helm-chart/actions/workflows/release.yaml)

A single place to define a complete observability stack: the [`lgtm`](charts/lgtm/) umbrella chart bundles Loki, Grafana, Tempo, Prometheus and Pyroscope (all single-binary), the OpenTelemetry Operator with three managed collectors, correlated Grafana datasources and OTel-native dashboards — one `helm install` per cluster.

```bash
helm repo add promptlylabs https://promptlylabs.github.io/lgtm-helm-chart
helm install lgtm promptlylabs/lgtm -n observability --create-namespace \
  --set collectors.enabled=false   # two-phase first install, see chart README
helm upgrade lgtm promptlylabs/lgtm -n observability \
  --reuse-values --set collectors.enabled=true
```

Full documentation in the [chart README](charts/lgtm/README.md). Architectural decisions are recorded as [ADRs](docs/adrs/).

## Development

```bash
make values       # regenerate charts/lgtm/values.yaml from values.d/ fragments
make deps         # helm repo add + dependency build
make lint template kubeconform
make docs-validate
```

Chart defaults are maintained as per-component fragments in [`charts/lgtm/values.d/`](charts/lgtm/values.d/); `values.yaml` is generated ([ADR-0007](docs/adrs/0007-values-assembled-from-fragments.md)). Releases are GPG-signed and published to GitHub Pages / ArtifactHub by [chart-releaser](.github/workflows/release.yaml) on every push to `main` — bump `charts/lgtm/Chart.yaml` `version` in your PR.

Dependencies are managed by [Renovate](renovate.json5) ([ADR-0008](docs/adrs/0008-automated-dependency-updates-renovate.md)): non-major updates arrive as one grouped weekly PR that bumps the chart version and automerges once the `lint` and `smoke` checks pass; upstream majors arrive as separate `major-upstream` PRs that need a human to adapt `values.d/` if necessary and decide whether the chart's own values contract broke (only then is the chart version manually bumped to a new major). The kind-based [smoke test](.github/workflows/smoke.yaml) installs the full stack and asserts traces, metrics, logs and Grafana provisioning end to end on every PR.

## License

[Apache-2.0](LICENSE)
