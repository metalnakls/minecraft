#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "This installer requires macOS." >&2; exit 1; }
mcsetup=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-setup.XXXXXX")
trap 'rm -rf "$mcsetup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 4 --retry-all-errors 'https://github.com/metalnakls/minecraft/releases/download/launcher-1.3.7-91/install.sh' -o "$mcsetup/install.sh"
printf '%s  %s\n' '4abde8a1e5904047502d736604160723e1c3455a6c9ae19bd7268738234d5aa2' "$mcsetup/install.sh" | /usr/bin/shasum -a 256 -c -
/bin/bash "$mcsetup/install.sh" --release 'https://github.com/metalnakls/minecraft/releases/download/launcher-1.3.7-91' --allow-adhoc "$@"
