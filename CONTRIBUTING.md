# Contributing

Thanks for your interest in improving `lgtm-helm-chart`. This is an opinionated observability umbrella chart, so changes are expected to keep the stack coherent and to pass the full lint + smoke + docs gates before merge. This guide covers everything you need to get there; the [README](README.md) and the [chart README](charts/lgtm/README.md) explain what the chart does.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). To report a security vulnerability, follow the [Security Policy](SECURITY.md) instead of opening a public issue.

## Prerequisites

You will need: [`helm`](https://helm.sh/) (v3), `python3`, [`kubectl`](https://kubernetes.io/docs/tasks/tools/), [`kind`](https://kind.sigs.k8s.io/) (to reproduce the smoke test locally), [`pre-commit`](https://pre-commit.com/), [`kubeconform`](https://github.com/yannh/kubeconform), and [`ct` (chart-testing)](https://github.com/helm/chart-testing). Most are available via Homebrew (`brew install helm kind kubeconform chart-testing pre-commit`).

## How this chart is built

`charts/lgtm/values.yaml` is **generated** — never edit it by hand. Chart defaults live as per-component fragments in [`charts/lgtm/values.d/`](charts/lgtm/values.d/) (e.g. `30-grafana.yaml`, `40-loki.yaml`), and [`scripts/assemble_values.py`](scripts/assemble_values.py) concatenates them, ordered by filename, into `values.yaml` ([ADR-0007](docs/adrs/0007-values-assembled-from-fragments.md)). Two fragments may not declare the same top-level key — the assembler fails loudly if they do, which catches accidental shadowing. After editing any fragment, run `make values`; `make check-values` is the CI guard that fails the build if `values.yaml` is stale.

## Local workflow

```bash
make deps          # add helm repos + build chart dependencies (run once, and after any Chart.yaml dep change)
make values        # regenerate charts/lgtm/values.yaml from values.d/ fragments
make all           # values → deps → lint → template → kubeconform
make docs-validate # validate docs/ against the docs-framework
```

`make all` is the fast inner loop and mirrors most of CI. Install the git hooks once with `pre-commit install` — they run [gitleaks](https://github.com/gitleaks/gitleaks) (secret scanning) and re-assemble `values.yaml` on every commit that touches `values.d/`.

To reproduce the end-to-end smoke test locally, create a kind cluster and install the stack in two phases (collectors off, then on) — see [`.github/workflows/smoke.yaml`](.github/workflows/smoke.yaml) for the exact steps and assertions.

## What CI checks

Every pull request must pass these checks before it can merge:

- **lint** — `make check-values`, then `ct lint` and `helm lint`, then `helm template` across the default values, `collectors.enabled=false`, and every overlay in [`charts/lgtm/examples/`](charts/lgtm/examples/), validated with `kubeconform` against Kubernetes and CRD schemas.
- **smoke** — a kind cluster installs the full stack (two-phase) and asserts traces reach Tempo, host metrics reach Prometheus, logs reach Loki, Grafana provisions its datasources and dashboards, and no collector logs errors.
- **gitleaks** — scans the diff for committed secrets.

Documentation under `docs/` is validated locally with `make docs-validate`; it isn't a CI gate on this public repo because the docs-framework check depends on a private action.

If you add a new capability, make sure it renders cleanly under the example overlays in `charts/lgtm/examples/values-*.yaml` (the lint job templates all of them), and add an overlay if it warrants one.

## Commit messages

We follow [Conventional Commits](https://www.conventionalcommits.org/): `feat`, `fix`, `docs`, `chore`, `perf`, `ci`, optionally scoped (e.g. `fix(ci): …`, `feat: …`). GitHub release notes are generated from commit and PR titles, so keep them descriptive.

## Versioning

Most dependency bumps are automated by [Renovate](renovate.json5) ([ADR-0008](docs/adrs/0008-automated-dependency-updates-renovate.md)) and bump the chart version for you. For human-authored changes that alter the chart, bump `version` in [`charts/lgtm/Chart.yaml`](charts/lgtm/Chart.yaml) in your PR — patch for fixes, minor for additive changes, major only when the chart's own values contract breaks. `appVersion` is date-based (`YYYY.MM`) since the stack has no single upstream version.

## Architecture decisions

Significant or non-obvious design choices are recorded as [ADRs](docs/adrs/). If your change introduces or revisits one, add an ADR following the existing frontmatter format and run `make docs-validate`. The existing ADRs are also the best place to understand *why* the chart is shaped the way it is before proposing a change.

## Opening a pull request

1. Fork and branch from `main`.
2. Make your change; run `make all` (and `make docs-validate` if you touched `docs/`) until green.
3. Bump the chart version if the chart changed; add or update an ADR for design changes.
4. Open a PR against `main` and fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md). CI will run lint, smoke and gitleaks.

Questions about *using* the chart belong in the [chart README](charts/lgtm/README.md); this guide is about *changing* it. Thanks for contributing!
