#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "This installer requires macOS." >&2; exit 1; }
mcsetup=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-setup.XXXXXX")
trap 'rm -rf "$mcsetup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 4 --retry-all-errors --retry-max-time 90 --connect-timeout 20 --max-time 120 'https://metalnakls.github.io/minecraft/installers/f87ff174a8a393b90ac12bd11d776cc84c3c82caa73ae9bb4fa3f216971ecce2.sh' -o "$mcsetup/install.sh"
printf '%s  %s\n' 'f87ff174a8a393b90ac12bd11d776cc84c3c82caa73ae9bb4fa3f216971ecce2' "$mcsetup/install.sh" | /usr/bin/shasum -a 256 -c -
/bin/bash "$mcsetup/install.sh" --release 'https://github.com/metalnakls/minecraft/releases/download/3.9' --allow-adhoc "$@"
