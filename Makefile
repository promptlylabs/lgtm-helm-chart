CHART := charts/lgtm

.PHONY: values check-values deps lint validate-dashboards validate-alerts template kubeconform docs-validate all

## Assemble charts/lgtm/values.yaml from values.d/ fragments
values:
	python3 scripts/assemble_values.py

## Fail if values.yaml is out of sync with values.d/ (used in CI)
check-values:
	python3 scripts/assemble_values.py --check

## Fetch chart dependencies pinned in Chart.lock
deps:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
	helm dependency build $(CHART)

lint: check-values validate-dashboards validate-alerts
	helm lint $(CHART)

## Validate Grafana dashboard JSON (well-formed + datasource refs resolve)
validate-dashboards:
	python3 scripts/validate_dashboards.py

## Validate the rendered Grafana alert rules (provisioning schema + datasource refs).
## Needs PyYAML and chart dependencies (`make deps`) — the rule files are templates.
validate-alerts:
	python3 scripts/validate_alerts.py

## Render the chart in the default, collectors-off, and every example configuration
template: check-values
	helm template lgtm $(CHART) --namespace observability > /dev/null
	helm template lgtm $(CHART) --namespace observability --set collectors.enabled=false > /dev/null
	for f in $(CHART)/examples/values-*.yaml; do \
		helm template lgtm $(CHART) --namespace observability -f $$f > /dev/null || exit 1; \
	done
	@echo "all template permutations rendered"

## Validate rendered manifests against Kubernetes + CRD schemas
kubeconform: check-values
	helm template lgtm $(CHART) --namespace observability | kubeconform \
		-strict -ignore-missing-schemas \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# The validator needs a checkout of the framework repo for the taxonomy files
# (the uvx wheel only ships the tooling). Clone once into .cache/.
DOCS_FW_VERSION := 0.7.0
DOCS_FW_ROOT := .cache/docs-framework

docs-validate:
	@test -d $(DOCS_FW_ROOT) || git clone --depth 1 --branch v$(DOCS_FW_VERSION) https://github.com/promptlylabs/docs-framework $(DOCS_FW_ROOT)
	DOCS_FRAMEWORK_ROOT=$(DOCS_FW_ROOT) uvx --from 'git+https://github.com/promptlylabs/docs-framework@v$(DOCS_FW_VERSION)#subdirectory=tooling' docs-framework validate docs/

all: values deps lint template kubeconform
