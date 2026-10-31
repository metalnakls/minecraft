#!/bin/bash
set -euo pipefail
allow_adhoc=false
if [[ "${1:-}" == --allow-adhoc ]]; then allow_adhoc=true; shift; fi
if [[ $# -ne 4 ]]; then
    echo 'Usage: finalize-release.sh [--allow-adhoc] APP JAVA_MANIFEST SHADER_JAR PINNED_SHADER_HTTPS_URL' >&2
    exit 1
fi
here=$(cd "$(dirname "$0")" && pwd)
app="$1"
case "$4" in https://github.com/metalnakls/minecraftmetalshaders/releases/download/*) ;; *) echo 'Use a pinned shader fork release asset URL.' >&2; exit 1;; esac
codesign --verify --deep --strict "$app"
if [[ "$allow_adhoc" == true ]]; then
    codesign -dv "$app" 2>&1 | grep '^Signature=adhoc$' >/dev/null || { echo 'Expected an ad-hoc signed app.' >&2; exit 1; }
    echo 'Preparing the explicitly selected ad-hoc release; no Apple notarization.'
else
    codesign -dv "$app" 2>&1 | grep '^Authority=Developer ID Application:' >/dev/null || { echo 'Developer ID Application signature is required for this mode.' >&2; exit 1; }
    xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute "$app"
fi
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
