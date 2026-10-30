#!/bin/bash
set -euo pipefail
if [[ $# -ne 4 ]]; then
    echo 'Usage: finalize-release.sh SIGNED_STAPLED_APP JAVA_MANIFEST SHADER_JAR PINNED_SHADER_HTTPS_URL' >&2
    exit 1
fi
here=$(cd "$(dirname "$0")" && pwd)
app="$1"
case "$4" in https://github.com/metalnakls/minecraftmetalshaders/releases/download/*) ;; *) echo 'Use a pinned shader fork release asset URL.' >&2; exit 1;; esac
codesign --verify --deep --strict "$app"
codesign -dv "$app" 2>&1 | grep -q '^Authority=Developer ID Application:' || { echo 'Developer ID Application signature is required for distribution.' >&2; exit 1; }
xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute "$app"
python3 "$here/prepare.py" --app "$app" --java-manifest "$2" --shader-jar "$3" \
  --shader-url "$4" --bundled-mod 'macos-input-fixes-1.13+26.3.jar' --require-resolved
git -C "$here/.." archive --format=tar.gz --prefix=minecraft-source/ -o "$here/release/launcher-source.tar.gz" HEAD
cp "$here/install-skin.sh" "$here/release/install-skin.sh"
python3 - "$here/release" <<'PY'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1])
(root/'SHA256SUMS').write_text(''.join(hashlib.file_digest(p.open('rb'),'sha256').hexdigest()+'  '+p.name+'\n' for p in sorted(root.iterdir()) if p.is_file() and p.name!='SHA256SUMS'))
PY
printf 'Prepared local distribution artifacts in %s\nNothing uploaded. Run --dry-run after the proposed shader release exists.\n' "$here/release"
