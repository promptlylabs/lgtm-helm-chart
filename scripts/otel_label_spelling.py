#!/usr/bin/env python3
"""Catch OTel resource attributes spelled with underscores in PromQL.

This chart ingests OTLP into Prometheus with `translationStrategy: NoTranslation`
(values.yaml), which keeps metric names *and* label names dotted. A promoted
resource attribute is therefore the label `k8s.pod.name`, and PromQL only reaches
it quoted:

    {"k8s.container.restarts", "k8s.pod.name"=~"..."}      max by ("k8s.pod.name") (...)

The underscored spelling `k8s_pod_name` belongs to **Loki**, whose OTLP ingestion
does sanitise attribute names to underscores — which is why datasources.yaml uses
it, correctly. Mixing the two is the failure this module exists to prevent, and it
is nasty precisely because nothing complains: an underscored name is a perfectly
legal label name that simply matches no series. The query returns empty, the rule
reports health=ok and parks in noDataState, the dashboard panel shows an empty
column. Chart 0.18.0 shipped with the Target Allocator restart alert — the one
rule the pack was written for — dead this way, plus an empty Version column on the
OTel Collector dashboard, and every existing check passed.

The alias list is derived from `promoteResourceAttributes` in values.yaml rather
than hardcoded, so it cannot drift from what Prometheus is actually configured to
promote.

Applies to the prometheus datasource ONLY. Loki expressions are underscored on
purpose; passing them here would produce false positives.
"""

import re
from pathlib import Path

VALUES = Path(__file__).resolve().parent.parent / "charts" / "lgtm" / "values.yaml"

# A label matcher's left-hand side: preceded by `{` or `,`, followed by an
# operator. Metric names cannot match — they sit outside the braces, or inside as
# a quoted string with no operator after them.
_MATCHER_LHS = re.compile(r'[{,]\s*("?)([A-Za-z_][A-Za-z0-9_]*)\1\s*(?:=~|!~|!=|=)')
# Everything in a grouping/matching clause is a label name by definition.
_GROUPING = re.compile(
    r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\(([^)]*)\)"
)
# Grafana's own template-variable helper, in both its forms:
# label_values(<selector>, <label>) and label_values(<label>).
_LABEL_VALUES = re.compile(
    r"label_values\((?:[^,]*,\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*\)"
)


def promoted_aliases(values_path: Path = VALUES) -> dict[str, str]:
    """Map each promoted dotted attribute to the underscored spelling of it.

    Parsed with a regex rather than yaml.safe_load so that validate_dashboards.py,
    which has no other YAML dependency, can use this too.
    """
    text = values_path.read_text()
    block = re.search(
        r"promoteResourceAttributes:\n((?:[ \t]*#.*\n|[ \t]*-[ \t]*\S+\n)+)", text
    )
    if not block:
        raise SystemExit(
            f"error: no promoteResourceAttributes list found in {values_path} — "
            "this lint is derived from it and cannot run without it"
        )
    attrs = [
        line.strip()[2:].strip()
        for line in block.group(1).splitlines()
        if line.strip().startswith("- ")
    ]
    dotted = [a for a in attrs if "." in a]
    if not dotted:
        raise SystemExit(f"error: promoteResourceAttributes in {values_path} has no dotted names")
    return {a.replace(".", "_"): a for a in dotted}


def find_violations(expr: str, aliases: dict[str, str]) -> dict[str, str]:
    """Underscored label names in `expr`, mapped to their correct dotted form."""
    names: set[str] = set()

    for _, name in _MATCHER_LHS.findall(expr):
        names.add(name)
    for clause in _GROUPING.findall(expr):
        for name in re.split(r"[,\s]+", clause):
            names.add(name.strip().strip('"'))
    names.update(_LABEL_VALUES.findall(expr))

    return {n: aliases[n] for n in sorted(names) if n in aliases}


def describe(where: str, expr: str, violations: dict[str, str]) -> str:
    """A one-line error naming the fix, for the calling validator's error list."""
    fixes = ", ".join(f'{bad} -> "{good}"' for bad, good in violations.items())
    return (
        f"{where}: OTel resource attribute spelled with underscores in a prometheus "
        f"query ({fixes}). Under translationStrategy: NoTranslation these labels keep "
        f"their dots and must be quoted; the underscored form is Loki's and matches "
        f"nothing here, so the query silently returns empty. Expression: {expr[:120]}"
    )
