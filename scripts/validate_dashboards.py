#!/usr/bin/env python3
"""Static validation of the Grafana dashboard JSON in charts/lgtm/dashboards/.

CI installs the stack and counts that the dashboards provision, but it never
parses them — so a malformed dashboard or a panel pointing at a datasource UID
that this chart does not provision ships silently. This check closes the static
half of that gap (metric existence is covered at runtime by the smoke test):

  1. every dashboards/*.json parses as JSON;
  2. every `datasource` reference (at any depth) resolves to either
     - a datasource UID this chart provisions (templates/grafana/datasources.yaml),
     - a Grafana built-in ("-- Grafana --", "-- Mixed --", "-- Dashboard --"), or
     - a `${var}` whose template variable is defined in the same dashboard;
  3. no prometheus query spells a promoted OTel resource attribute with
     underscores (`service_version` instead of `"service.version"`). Under
     translationStrategy: NoTranslation those labels keep their dots; the
     underscored spelling is Loki's, and it matches nothing without erroring, so
     the panel just renders an empty column. See scripts/otel_label_spelling.py.

Usage:
    python3 scripts/validate_dashboards.py
"""

import json
import re
import sys
from pathlib import Path

from otel_label_spelling import describe, find_violations, promoted_aliases

DASHBOARDS_DIR = Path(__file__).resolve().parent.parent / "charts" / "lgtm" / "dashboards"

# UIDs and names provisioned by templates/grafana/datasources.yaml. Keep in sync
# with that file if a datasource is added/removed.
KNOWN_DATASOURCES = {"prometheus", "loki", "tempo", "pyroscope"}

VAR_REF = re.compile(r"^\$\{([^:}]+)")  # ${datasource} / ${datasource:json} -> datasource


def is_builtin(value: str) -> bool:
    v = value.strip()
    return v.startswith("-- ") and v.endswith(" --")


def collect_template_vars(dashboard: dict) -> set[str]:
    """Names of all template variables defined in the dashboard."""
    names: set[str] = set()
    for var in dashboard.get("templating", {}).get("list", []) or []:
        if isinstance(var, dict) and var.get("name"):
            names.add(var["name"])
    return names


def iter_datasource_refs(node):
    """Yield every value found under a `datasource` key, at any depth."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "datasource" and value is not None:
                yield value
            else:
                yield from iter_datasource_refs(value)
    elif isinstance(node, list):
        for item in node:
            yield from iter_datasource_refs(item)


def ref_to_string(ref) -> str | None:
    """Normalise a datasource ref (object {uid:..} or legacy string) to its uid/name."""
    if isinstance(ref, dict):
        return ref.get("uid")
    if isinstance(ref, str):
        return ref
    return None


def validate(path: Path, errors: list[str]) -> None:
    try:
        dashboard = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        errors.append(f"{path.name}: invalid JSON — {exc}")
        return

    template_vars = collect_template_vars(dashboard)

    for ref in iter_datasource_refs(dashboard):
        value = ref_to_string(ref)
        if value is None or value == "":
            continue  # default datasource — Grafana resolves it
        if is_builtin(value):
            continue
        match = VAR_REF.match(value)
        if match:
            var = match.group(1)
            if var not in template_vars:
                errors.append(
                    f"{path.name}: datasource references undefined template variable "
                    f"'${{{var}}}'"
                )
            continue
        if value.lower() not in KNOWN_DATASOURCES:
            errors.append(
                f"{path.name}: datasource uid '{value}' is not provisioned by this "
                f"chart (known: {', '.join(sorted(KNOWN_DATASOURCES))})"
            )


def iter_prometheus_exprs(node, ds_type=None, path="$"):
    """Yield (json path, query string) for every query on the prometheus datasource.

    Carries the nearest enclosing `datasource.type` down the tree, since panels
    declare it once and their targets inherit it. Loki queries are excluded on
    purpose — underscored label names are correct there.
    """
    if isinstance(node, dict):
        ref = node.get("datasource")
        if isinstance(ref, dict) and ref.get("type"):
            ds_type = ref["type"]
        for key in ("expr", "query", "definition"):
            value = node.get(key)
            if isinstance(value, str) and value and ds_type == "prometheus":
                yield f"{path}.{key}", value
        for key, value in node.items():
            yield from iter_prometheus_exprs(value, ds_type, f"{path}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from iter_prometheus_exprs(value, ds_type, f"{path}[{index}]")


def main() -> None:
    files = sorted(DASHBOARDS_DIR.glob("*.json"))
    if not files:
        sys.exit(f"error: no dashboards found in {DASHBOARDS_DIR}")

    errors: list[str] = []
    aliases = promoted_aliases()
    for path in files:
        validate(path, errors)
        try:
            dashboard = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue  # already reported by validate()
        for where, expr in iter_prometheus_exprs(dashboard):
            bad = find_violations(expr, aliases)
            if bad:
                errors.append(describe(f"{path.name} {where}", expr, bad))

    if errors:
        print("dashboard validation failed:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)

    print(
        f"validated {len(files)} dashboards — JSON well-formed, datasource refs "
        "resolve, no underscored OTel label names in prometheus queries"
    )


if __name__ == "__main__":
    main()
