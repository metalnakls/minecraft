#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "This installer requires macOS." >&2; exit 1; }
mcsetup=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-setup.XXXXXX")
trap 'rm -rf "$mcsetup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 4 --retry-all-errors --retry-max-time 90 --connect-timeout 20 --max-time 120 'https://metalnakls.github.io/minecraft/installers/94f00753627c6bc21d0f826017fabf8a363ef7bea81159181e6f047ab44ae128.sh' -o "$mcsetup/install.sh"
printf '%s  %s\n' '94f00753627c6bc21d0f826017fabf8a363ef7bea81159181e6f047ab44ae128' "$mcsetup/install.sh" | /usr/bin/shasum -a 256 -c -
/bin/bash "$mcsetup/install.sh" --release 'https://github.com/metalnakls/minecraft/releases/download/3.8' --allow-adhoc "$@"
