#!/bin/bash
set -euo pipefail
[[ $# -eq 2 ]] || { echo 'Usage: bash install-skin.sh ExactPlayerName /path/to/skin.png' >&2; exit 1; }
[[ "$1" =~ ^[A-Za-z0-9_]{3,16}$ ]] || { echo 'Use the exact Minecraft player name (3–16 letters, digits or underscores).' >&2; exit 1; }
[[ -f "$2" ]] || { echo 'Skin file not found.' >&2; exit 1; }
info=$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$2")
grep -q 'format: png' <<< "$info" || { echo 'The skin must be a PNG.' >&2; exit 1; }
grep -q 'pixelWidth: 64' <<< "$info" || { echo 'Use a standard 64×64 or 64×32 skin.' >&2; exit 1; }
grep -Eq 'pixelHeight: (64|32)$' <<< "$info" || { echo 'Use a standard 64×64 or 64×32 skin.' >&2; exit 1; }
dir="$HOME/Library/Application Support/minecraft/home/Fabric 26.3/CustomSkinLoader/LocalSkin/skins"
mkdir -p "$dir"
dest="$dir/$1.png"
if [[ -f "$dest" ]]; then
    if cmp -s "$2" "$dest"; then echo 'This skin is already installed.'; exit; fi
    backup=$(mktemp "$dest.backup.XXXXXX"); cp "$dest" "$backup"
fi
cp "$2" "$dest"
printf 'Installed %s\nRepeat for BOTH players on BOTH Macs, then restart Minecraft.\n' "$dest"
