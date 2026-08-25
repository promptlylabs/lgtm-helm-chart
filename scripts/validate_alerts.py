#!/usr/bin/env python3
"""Static validation of the Grafana alert rules in charts/lgtm/alerts/.

The rule files are Helm templates (they call the shared lgtm.alerting.query
helper), so unlike the dashboards they cannot be parsed off disk — this renders
the chart first and validates what the alerts sidecar would actually be handed:

  1. every lgtm-alert-* ConfigMap carries the grafana_alert: "1" label;
  2. its data value parses as YAML and is Grafana provisioning apiVersion 1;
  3. every rule has the A/B/C data[] triple with condition: C;
  4. every non-expression datasourceUid resolves to a datasource this chart
     provisions (templates/grafana/datasources.yaml);
  5. rule uids and titles are unique across the whole pack.

Runtime coverage (do the queries return anything?) is the smoke test's job.

Usage:
    python3 scripts/validate_alerts.py
"""

import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CHART_DIR = REPO_ROOT / "charts" / "lgtm"

# Keep in sync with templates/grafana/datasources.yaml, as validate_dashboards.py does.
KNOWN_DATASOURCES = {"prometheus", "loki", "tempo", "pyroscope"}

EXPR_DATASOURCE = "__expr__"


def render() -> str:
    proc = subprocess.run(
        [
            "helm", "template", "lgtm", str(CHART_DIR),
            "--namespace", "observability",
            "--show-only", "templates/grafana/alerting.yaml",
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"error: helm template failed\n{proc.stderr}")
    return proc.stdout


def main() -> None:
    errors: list[str] = []
    uids: dict[str, str] = {}
    titles: dict[str, str] = {}
    rule_count = 0

    configmaps = [doc for doc in yaml.safe_load_all(render()) if doc]
    if not configmaps:
        sys.exit("error: rendering templates/grafana/alerting.yaml produced nothing")

    for cm in configmaps:
        name = cm["metadata"]["name"]
        if cm["metadata"].get("labels", {}).get("grafana_alert") != '1':
            errors.append(f"{name}: missing grafana_alert: \"1\" label — the sidecar will skip it")

        for key, body in cm.get("data", {}).items():
            where = f"{name}/{key}"
            try:
                provisioning = yaml.safe_load(body)
            except yaml.YAMLError as exc:
                errors.append(f"{where}: not valid YAML — {exc}")
                continue

            if provisioning.get("apiVersion") != 1:
                errors.append(f"{where}: apiVersion must be 1, got {provisioning.get('apiVersion')!r}")

            for group in provisioning.get("groups", []):
                for rule in group.get("rules", []):
                    rule_count += 1
                    uid = rule.get("uid", "<no uid>")
                    ref_ids = [d.get("refId") for d in rule.get("data", [])]

                    if uid in uids:
                        errors.append(f"{where}: duplicate rule uid {uid!r} (also in {uids[uid]})")
                    uids[uid] = where

                    title = rule.get("title")
                    if title in titles:
                        errors.append(f"{where}: duplicate rule title {title!r} (also in {titles[title]})")
                    titles[title] = where

                    if ref_ids != ["A", "B", "C"]:
                        errors.append(f"{where}/{uid}: expected data refIds [A, B, C], got {ref_ids}")
                    if rule.get("condition") != "C":
                        errors.append(f"{where}/{uid}: condition must be C, got {rule.get('condition')!r}")

                    for datum in rule.get("data", []):
                        ds = datum.get("datasourceUid")
                        if ds != EXPR_DATASOURCE and ds not in KNOWN_DATASOURCES:
                            errors.append(
                                f"{where}/{uid}: refId {datum.get('refId')} points at datasource "
                                f"{ds!r}, which this chart does not provision"
                            )

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        sys.exit(f"\n{len(errors)} problem(s) in the rendered alert rules")

    print(f"alerts OK — {len(configmaps)} ConfigMaps, {rule_count} rules")


if __name__ == "__main__":
    main()
