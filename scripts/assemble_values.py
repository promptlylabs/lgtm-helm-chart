#!/usr/bin/env python3
"""Assemble charts/lgtm/values.yaml from the charts/lgtm/values.d/ fragments.

Each fragment owns a disjoint set of top-level keys; assembly is plain
concatenation in filename order. The script fails if two fragments declare
the same top-level key, so a typo can't silently shadow another component's
defaults.

Usage:
    python3 scripts/assemble_values.py          # write values.yaml
    python3 scripts/assemble_values.py --check  # fail if values.yaml is stale
"""

import re
import sys
from pathlib import Path

CHART_DIR = Path(__file__).resolve().parent.parent / "charts" / "lgtm"
FRAGMENTS_DIR = CHART_DIR / "values.d"
TARGET = CHART_DIR / "values.yaml"

HEADER = """\
# ─────────────────────────────────────────────────────────────────────────────
# GENERATED FILE — DO NOT EDIT.
#
# This file is assembled from the fragments in values.d/ by
# scripts/assemble_values.py (run `make values`). Edit the fragment that owns
# the top-level key you want to change, then regenerate.
# ─────────────────────────────────────────────────────────────────────────────
"""

TOP_LEVEL_KEY = re.compile(r'^([A-Za-z0-9_"][^:#]*):')


def assemble() -> str:
    fragments = sorted(FRAGMENTS_DIR.glob("*.yaml"))
    if not fragments:
        sys.exit(f"error: no fragments found in {FRAGMENTS_DIR}")

    seen: dict[str, Path] = {}
    parts = [HEADER]
    for fragment in fragments:
        text = fragment.read_text()
        for line in text.splitlines():
            match = TOP_LEVEL_KEY.match(line)
            if match:
                key = match.group(1).strip().strip('"')
                if key in seen and seen[key] != fragment:
                    sys.exit(
                        f"error: top-level key '{key}' defined in both "
                        f"{seen[key].name} and {fragment.name}"
                    )
                seen[key] = fragment
        parts.append(f"\n# ═══ {fragment.name} " + "═" * max(1, 60 - len(fragment.name)) + "\n\n")
        parts.append(text.rstrip("\n") + "\n")
    return "".join(parts)


def main() -> None:
    content = assemble()
    if "--check" in sys.argv:
        current = TARGET.read_text() if TARGET.exists() else ""
        if current != content:
            sys.exit(
                f"error: {TARGET.relative_to(CHART_DIR.parent.parent)} is out of "
                "sync with values.d/ — run `make values` and commit the result"
            )
        print("values.yaml is in sync with values.d/")
        return
    TARGET.write_text(content)
    print(f"wrote {TARGET.relative_to(CHART_DIR.parent.parent)} from {len(list(FRAGMENTS_DIR.glob('*.yaml')))} fragments")


if __name__ == "__main__":
    main()
