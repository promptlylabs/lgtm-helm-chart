<!-- Thanks for contributing! Please read CONTRIBUTING.md if you haven't. -->

## Summary

<!-- What does this change do, and why? Link any related issue (e.g. "Closes #123"). -->

## Type of change

<!-- Match your commit prefix (Conventional Commits). -->

- [ ] `feat` — new capability
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `chore` / `ci` — tooling, deps, or CI
- [ ] `perf` — performance

## Checklist

- [ ] I edited the `values.d/` fragments (not the generated `values.yaml`) and ran `make values`.
- [ ] `make all` passes locally (values → deps → lint → template → kubeconform).
- [ ] I bumped `version` in `charts/lgtm/Chart.yaml` (if the chart changed).
- [ ] I added or updated an ADR in `docs/adrs/` for design changes and ran `make docs-validate`.
- [ ] I updated the examples in `charts/lgtm/examples/` and/or the README if behaviour changed.
- [ ] No secrets are committed (gitleaks is clean).

<!-- CI will run lint, the kind smoke test and gitleaks on this PR. -->
