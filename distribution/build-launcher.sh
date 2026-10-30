#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'Usage: build-launcher.sh /absolute/output-directory' >&2; exit 1; }
case "$1" in /*) ;; *) echo 'Output directory must be absolute.' >&2; exit 1;; esac
root=$(cd "$(dirname "$0")/.." && pwd)
out="$1"
mkdir -p "$out"
cd "$root"
git diff --exit-code -- . ':!distribution' >/dev/null || { echo 'Commit application changes before building a release.' >&2; exit 1; }
git rev-parse HEAD > "$out/launcher-source-revision.txt"
# Preserve configured signing; this does not replace a missing Developer ID identity.
xcodebuild -project SwiftCraftLauncher.xcodeproj -scheme SwiftCraftLauncher \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$out/derived" -archivePath "$out/Minecraft.xcarchive" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES archive > "$out/build.log" 2>&1
codesign --verify --deep --strict "$out/Minecraft.xcarchive/Products/Applications/Minecraft.app"
git archive --format=tar.gz --prefix=minecraft-source/ -o "$out/launcher-source.tar.gz" HEAD
printf 'Local archive: %s\nBuild log: %s\n' "$out/Minecraft.xcarchive" "$out/build.log"
