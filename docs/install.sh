#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "This installer requires macOS." >&2; exit 1; }
mcsetup=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-setup.XXXXXX")
trap 'rm -rf "$mcsetup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 4 --retry-all-errors --retry-max-time 90 --connect-timeout 20 --max-time 120 'https://metalnakls.github.io/minecraft/installers/5c73655ef431ce015642bd8b8ecc06544aeaa3a5ac6778ad057aebdfb8e9b70d.sh' -o "$mcsetup/install.sh"
printf '%s  %s\n' '5c73655ef431ce015642bd8b8ecc06544aeaa3a5ac6778ad057aebdfb8e9b70d' "$mcsetup/install.sh" | /usr/bin/shasum -a 256 -c -
/bin/bash "$mcsetup/install.sh" --release 'https://github.com/metalnakls/minecraft/releases/download/3.9.1' --allow-adhoc "$@"
