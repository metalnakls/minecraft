#!/bin/bash
# Release regression: test the archived executable, not an unstripped debug build.
set -euo pipefail
[[ $# -eq 2 ]] || { echo 'Usage: verify-launcher.sh APP JAVA_EXECUTABLE' >&2; exit 1; }
app="$1"
exe="$app/Contents/MacOS/Minecraft"
codesign --verify --deep --strict "$app"
nm -g "$exe" | grep ' T _main$' >/dev/null || { echo 'Missing exported JVM reentry point: main' >&2; exit 1; }
"$exe" --verify-java "$2"
xcrun assetutil --info "$app/Contents/Resources/Assets.car" | python3 -c '
import json,sys
assets=json.load(sys.stdin)
variants={a.get("Appearance") for a in assets if a.get("AssetType")=="IconImageStack" and a.get("Name")=="minecraft"}
assert {"NSAppearanceNameAqua","NSAppearanceNameDarkAqua","ISAppearanceTintable"} <= variants, variants
print("Verified native Java handoff and layered Icon Composer variants.")
'
