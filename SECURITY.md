# Security Policy

## Supported versions

This chart is pre-1.0 and ships from a single release line. Only the latest released chart version receives security fixes, delivered as a new patch release on top of it. Always upgrade to the most recent `lgtm` chart before reporting an issue, since the fix may already be published.

| Version | Supported |
| ------- | --------- |
| latest release | ✅ |
| older releases | ❌ |

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues, pull requests, or discussions.**

Report privately through GitHub's [private vulnerability reporting](https://github.com/promptlylabs/lgtm-helm-chart/security/advisories/new) — open the repository's **Security** tab and choose **Report a vulnerability**. This keeps the report confidential until a fix is available and lets us coordinate a disclosure with you.

To help us triage quickly, please include:

- the affected chart version (`helm list` / `Chart.yaml` `version`);
- your Kubernetes version and distribution (kind, EKS, GKE, AKS, Talos, k3s, …);
- the relevant `values` overrides or rendered manifests;
- a description of the impact and, where possible, steps to reproduce.

We will acknowledge your report, keep you updated on our progress, and credit you in the release notes once a fix ships — unless you prefer to remain anonymous.

## Scope

This is an umbrella chart that packages upstream components — Loki, Grafana, Tempo, kube-prometheus-stack, Pyroscope and the OpenTelemetry Operator. Vulnerabilities **in those upstream projects** are best reported to their respective maintainers, who own the fix. Report here when the weakness is in **this chart's packaging, defaults or generated configuration** — for example an insecure default value, an over-broad RBAC grant, or a secret exposed by our templates — even if it surfaces through an upstream component.
