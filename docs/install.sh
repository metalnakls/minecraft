#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "This installer requires macOS." >&2; exit 1; }
mcsetup=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-setup.XXXXXX")
trap 'rm -rf "$mcsetup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 4 --retry-all-errors 'https://metalnakls.github.io/minecraft/installers/0d3bec1213c38d7fe39e1a81fd4d137c905a991867b8b1613b0fe8ee52f9c16d.sh' -o "$mcsetup/install.sh"
printf '%s  %s\n' '0d3bec1213c38d7fe39e1a81fd4d137c905a991867b8b1613b0fe8ee52f9c16d' "$mcsetup/install.sh" | /usr/bin/shasum -a 256 -c -
/bin/bash "$mcsetup/install.sh" --release 'https://github.com/metalnakls/minecraft/releases/download/launcher-1.3.7-91' --allow-adhoc "$@"
