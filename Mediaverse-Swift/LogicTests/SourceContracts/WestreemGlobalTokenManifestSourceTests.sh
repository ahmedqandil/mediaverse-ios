#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
manifest="$root/Resources/DesignSystem/westreem-global-tokens.v1.json"
tokens="$root/Social/Vibes/DesignTokens.swift"

python3 - "$manifest" "$tokens" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
tokens_path = pathlib.Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text())
expected_hash = manifest.pop("manifestHash")
canonical = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
actual_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
assert actual_hash == expected_hash == "b27439e8670567977c979c78b3f33b61e2a5bd3ecd742c74199f52e028aa6bc0"
assert manifest["scope"] == "all-westreem-product-surfaces"
assert manifest["authority"] == {
    "definition": "Streem Design System.html",
    "excluded": ["AI build brief.md"],
    "implementationConstraints": "WeStreem Platform Spec.html",
}

source = tokens_path.read_text()
assert 'static let contractVersion = "2026-08-05.1"' in source
for value in manifest["color"].values():
    assert value in source, f"missing iOS color binding {value}"
for value in manifest["spacing"]:
    assert f"CGFloat = {value}" in source, f"missing iOS spacing {value}"
for name, value in manifest["radius"].items():
    assert f"static let {name}: CGFloat = {value}" in source, f"missing iOS radius {name}"
for family in manifest["typography"].values():
    assert family in source, f"missing iOS font family {family}"
PY

echo "WeStreem global Design System token manifest contract passed."
