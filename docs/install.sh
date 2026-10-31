#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "This installer requires macOS." >&2; exit 1; }
mcsetup=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-setup.XXXXXX")
trap 'rm -rf "$mcsetup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 4 --retry-all-errors --retry-max-time 90 --connect-timeout 20 --max-time 120 'https://metalnakls.github.io/minecraft/installers/e8e6d9c85cad14c1ce9b51c2f802fc421d8f563934b83b1bab8ad229206dc8f4.sh' -o "$mcsetup/install.sh"
printf '%s  %s\n' 'e8e6d9c85cad14c1ce9b51c2f802fc421d8f563934b83b1bab8ad229206dc8f4' "$mcsetup/install.sh" | /usr/bin/shasum -a 256 -c -
/bin/bash "$mcsetup/install.sh" --release 'https://github.com/metalnakls/minecraft/releases/download/launcher-1.3.7-91' --allow-adhoc "$@"
