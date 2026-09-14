#!/usr/bin/env python3
"""Write kubeconform JSON schemas for the CRDs this chart installs.

`make kubeconform` used to validate every custom resource against the community
datreeio/CRDs-catalog alone. That catalog trails the operators this chart pins:
it carried the OpenTelemetryCollector schema of operator 0.151.0 while the chart
deploys 0.158.0, so fields the pinned CRD accepts (targetAllocator
allowInsecureAuthSecrets / mtls, ADR-0018) failed validation as "additional
properties not allowed". Validating against the CRDs we actually install is
both stricter and correct: the chart's CRs are checked against exactly the
schema the API server will enforce.

Reads a rendered manifest stream on stdin — `helm template --include-crds`, so
it sees both the plain crds/ directories and the operator's templated CRDs — and
writes <out>/<group>/<kind>_<version>.json for every CustomResourceDefinition,
the layout `-schema-location '<out>/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
expects. The conversion mirrors kubeconform's own openapi2jsonschema.py: every
object that declares properties gets additionalProperties: false (what makes
-strict meaningful for custom resources), except where the CRD says
x-kubernetes-preserve-unknown-fields; `format: int-or-string` becomes a
string-or-integer union.

Usage: helm template ... --include-crds | scripts/crd_schemas.py <output-dir>
"""
import json
import pathlib
import sys

import yaml


class Loader(yaml.SafeLoader):
    """SafeLoader minus YAML 1.1's "value" tag, which makes a bare "=" scalar
    unloadable. The prometheus-operator CRDs carry exactly that in their
    matcher enums (['!=', '=', '=~', '!~'])."""


Loader.yaml_implicit_resolvers = {
    first: [r for r in resolvers if r[0] != "tag:yaml.org,2002:value"]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def strict(node, root=True):
    if isinstance(node, dict):
        if node.get("format") == "int-or-string":
            node.pop("format")
            node.pop("type", None)
            node["oneOf"] = [{"type": "string"}, {"type": "integer"}]
        if (
            not root
            and "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
        for key, value in node.items():
            # The keys under "properties" are field names, not schemas.
            if key == "properties":
                for field in value.values():
                    strict(field, root=False)
            else:
                strict(value, root=False)
    elif isinstance(node, list):
        for item in node:
            strict(item, root=False)
    return node


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = pathlib.Path(sys.argv[1])
    written = 0
    for doc in yaml.load_all(sys.stdin, Loader=Loader):
        if not isinstance(doc, dict) or doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc["spec"]
        for version in spec.get("versions", []):
            schema = (version.get("schema") or {}).get("openAPIV3Schema")
            if not schema:
                continue
            path = out / spec["group"] / f"{spec['names']['kind'].lower()}_{version['name']}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(strict(schema)))
            written += 1
    if not written:
        sys.exit("no CustomResourceDefinitions on stdin — render with --include-crds")
    print(f"wrote {written} CRD schemas to {out}")


if __name__ == "__main__":
    main()
