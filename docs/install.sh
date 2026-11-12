#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "This installer requires macOS." >&2; exit 1; }
mcsetup=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-setup.XXXXXX")
trap 'rm -rf "$mcsetup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 4 --retry-all-errors --retry-max-time 90 --connect-timeout 20 --max-time 120 'https://metalnakls.github.io/minecraft/installers/cac2b3a148f3f6547a18d2c32ee96323c429b673fecab3130b942a3016c23cd5.sh' -o "$mcsetup/install.sh"
printf '%s  %s\n' 'cac2b3a148f3f6547a18d2c32ee96323c429b673fecab3130b942a3016c23cd5' "$mcsetup/install.sh" | /usr/bin/shasum -a 256 -c -
/bin/bash "$mcsetup/install.sh" --release 'https://github.com/metalnakls/minecraft/releases/download/4.1' --allow-adhoc "$@"
