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
  5. rule uids and titles are unique across the whole pack;
  6. every uid obeys Grafana's own limits (<=40 characters, [A-Za-z0-9_-]);
  7. no rate()/irate()/increase() is applied to a multi-name __name__ regex.

Point 6 is not pedantry. Grafana treats a provisioning failure at startup as
FATAL: it refuses to boot, so a single over-long uid in a ConfigMap crashloops
Grafana and takes the whole observability UI with it. That is exactly how this
check earned its place — a 43-character uid shipped, and the only thing that
caught it was nine minutes into the kind smoke test.

Point 7 is the other bug this file has already caught in anger. rate() strips
__name__ from its output, so `rate({__name__=~"a_total|b_total"}[5m])` yields
duplicate labelsets whenever both metrics share a labelset, and Prometheus fails
the query with "vector cannot contain metrics with the same labelset". The rule
then sits at health=error and never fires — a guard that looks provisioned and
is silently dead. It is also load-dependent, so CI can pass with it present.

Runtime coverage (do the queries return anything?) is the smoke test's job.

Usage:
    python3 scripts/validate_alerts.py
"""

import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CHART_DIR = REPO_ROOT / "charts" / "lgtm"

# Keep in sync with templates/grafana/datasources.yaml, as validate_dashboards.py does.
KNOWN_DATASOURCES = {"prometheus", "loki", "tempo", "pyroscope"}

EXPR_DATASOURCE = "__expr__"

# Grafana rejects longer uids outright, and rejects the whole provisioning file
# with them — which at startup means it does not boot at all.
MAX_UID_LENGTH = 40
UID_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")

# Grafana's own column limit for the rule title.
MAX_TITLE_LENGTH = 190

# rate()/irate()/increase() over a __name__ regex that can match more than one
# metric name. Detected on the rendered expression, so a Helm-generated rule is
# covered too.
RATE_OVER_NAME_REGEX = re.compile(
    r"\b(?:rate|irate|increase)\s*\(\s*\{[^}]*__name__\s*=~[^}]*\}"
)


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

                    if len(uid) > MAX_UID_LENGTH:
                        errors.append(
                            f"{where}: rule uid {uid!r} is {len(uid)} characters; Grafana's limit "
                            f"is {MAX_UID_LENGTH}. Provisioning fails at startup, so Grafana will "
                            "not boot at all"
                        )
                    if not UID_PATTERN.match(uid):
                        errors.append(f"{where}: rule uid {uid!r} must match [A-Za-z0-9_-]+")

                    title = rule.get("title")
                    if title in titles:
                        errors.append(f"{where}: duplicate rule title {title!r} (also in {titles[title]})")
                    titles[title] = where

                    if not title:
                        errors.append(f"{where}/{uid}: rule has no title")
                    elif len(title) > MAX_TITLE_LENGTH:
                        errors.append(
                            f"{where}/{uid}: title is {len(title)} characters; Grafana's limit is "
                            f"{MAX_TITLE_LENGTH}"
                        )

                    if ref_ids != ["A", "B", "C"]:
                        errors.append(f"{where}/{uid}: expected data refIds [A, B, C], got {ref_ids}")
                    if rule.get("condition") != "C":
                        errors.append(f"{where}/{uid}: condition must be C, got {rule.get('condition')!r}")
                    elif "C" not in ref_ids:
                        errors.append(f"{where}/{uid}: condition C has no matching entry in data[]")

                    for datum in rule.get("data", []):
                        expr = (datum.get("model") or {}).get("expr", "")
                        if expr and RATE_OVER_NAME_REGEX.search(expr):
                            errors.append(
                                f"{where}/{uid}: rate()/increase() over a __name__ regex. "
                                "rate() drops __name__, so matching several metric names yields "
                                "duplicate labelsets and the query fails at evaluation time "
                                "(health=error, rule never fires). Sum each metric name "
                                "separately and add the results instead"
                            )

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
