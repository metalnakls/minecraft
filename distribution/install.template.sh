#!/bin/bash
# Generated release installer. macOS ships every command used here; no brew/python/jq.
set -euo pipefail
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
hash() { /usr/bin/shasum -a "$1" "$2" | /usr/bin/awk '{print $1}'; }
get() { /usr/bin/curl --fail --location --silent --show-error --retry 4 --retry-all-errors --retry-max-time 90 --connect-timeout 10 --max-time 300 --proto '=https' --proto-redir '=https' "$1" -o "$2"; }
safe_path() { case "$1" in ''|/*|../*|*/../*|*/..|*\\*) fail "Unsafe path: $1";; esac; }

resolve_url() {
    local url="$1" release="$2" json="$3" actual i candidate
    if [[ "$url" == modrinth:* ]]; then
        actual=${url#modrinth:}
        [[ "$actual" =~ ^[0-9a-f]{128}$ ]] || fail 'Invalid mod hash'
        get "https://api.modrinth.com/v2/version_file/$actual?algorithm=sha512" "$json" || return 1
        i=0; url=''
        while candidate=$(/usr/bin/plutil -extract "files.$i.hashes.sha512" raw -o - "$json" 2>/dev/null); do
            if [[ "$candidate" == "$actual" ]]; then
                url=$(/usr/bin/plutil -extract "files.$i.url" raw -o - "$json"); break
            fi
            i=$((i+1))
        done
        rm -f "$json"
        [[ "$url" == https://* ]] || return 1
    fi
    printf '%s\n' "${url/@RELEASE@/$release}"
}

probe_row() {
    local release="$1" report="$2" row="$3" algorithm expected mode path url tmp status reason=''
    IFS=$'\t' read -r algorithm expected mode path url <<< "$row"
    safe_path "$path"
    tmp=$(mktemp "${TMPDIR:-/tmp}/minecraft-probe.XXXXXX")
    if url=$(resolve_url "$url" "$release" "$tmp" 2> "$tmp.error"); then
        if [[ "$url" == /* ]]; then
            if [[ -f "$url" ]] && [[ "$(hash "$algorithm" "$url")" == "$expected" ]]; then status=OK; else status=FAIL; reason='Local release file missing or checksum mismatch'; fi
        elif /usr/bin/curl --fail --location --head --silent --show-error --retry 4 --retry-all-errors --retry-max-time 45 --connect-timeout 10 --max-time 30 --proto '=https' --proto-redir '=https' "$url" > "$tmp" 2> "$tmp.error"; then
            status=OK
        else
            status=FAIL
        fi
    else
        status=FAIL
        url='Exact mod hash could not be resolved through Modrinth'
    fi
    if [[ "$status" == FAIL && -z "$reason" && -f "$tmp.error" ]]; then
        reason=$(tr '\n\t' '  ' < "$tmp.error" | cut -c 1-300)
    fi
    # A single write keeps parallel worker result lines intact.
    printf '%s\t%s\t%s\t%s\n' "$status" "$path" "$url" "$reason" >> "$report"
    [[ "$status" == OK ]] || printf 'Unavailable or unverifiable: %s (%s): %s\n' "$path" "$url" "$reason" >&2
    rm -f "$tmp" "$tmp.error"
    [[ "$status" == OK ]]
}

fetch_row() {
    local release="$1" cache="$2" stage="$3" row="$4"
    local algorithm expected mode path url cached tmp json i candidate actual
    IFS=$'\t' read -r algorithm expected mode path url <<< "$row"
    safe_path "$path"
    case "$algorithm" in 1|256) ;; *) fail 'Invalid hash algorithm';; esac
    case "$mode" in 644|755) ;; *) fail 'Invalid permissions';; esac
    [[ "$expected" =~ ^[0-9a-f]+$ ]] || fail 'Invalid digest'
    cached="$cache/$algorithm-$expected"
    if [[ ! -f "$cached" ]] || [[ "$(hash "$algorithm" "$cached")" != "$expected" ]]; then
        tmp=$(mktemp "$cache/transfer.XXXXXX")
        url=$(resolve_url "$url" "$release" "$tmp.json") || fail "Cannot resolve exact mod: $path"
        if [[ "$url" == /* ]]; then cp "$url" "$tmp"; else get "$url" "$tmp"; fi
        [[ "$(hash "$algorithm" "$tmp")" == "$expected" ]] || fail "Checksum mismatch: $path"
        mv "$tmp" "$cached"
    fi
    mkdir -p "$stage/$(dirname "$path")"
    cp "$cached" "$stage/$path"
    chmod "$mode" "$stage/$path"
}

if [[ "${1:-}" == --fetch-row ]]; then shift; fetch_row "$@"; exit; fi
if [[ "${1:-}" == --probe-row ]]; then shift; probe_row "$@"; exit; fi

usage() {
    cat <<'EOF'
Usage: bash install.sh --check
       bash install.sh --release https://github.com/OWNER/REPO/releases/download/TAG [--dry-run|--download-only]
       bash install.sh --local-release /absolute/path/to/release [--dry-run|--download-only]

Installs the pinned Apple Silicon setup into ~/Applications/Minecraft.app and
~/Library/Application Support/minecraft. Existing game profiles and launchers
are never overwritten. No sudo, firewall changes, account copying or auto-launch.
--dry-run downloads only small manifests into a temporary folder and checks all
remote URLs with HEAD requests. It does not install files or change settings.
URL availability is not a checksum check; installation verifies every download.
EOF
}
release=''; mode=install
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) mode=check; shift;;
        --dry-run) mode=dry; shift;;
        --download-only) mode=download; shift;;
        --release|--local-release) [[ $# -gt 1 ]] || fail 'Missing release location'; release="$2"; shift 2;;
        --help|-h) usage; exit;;
        *) fail "Unknown argument: $1";;
    esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'This installer requires macOS.'
[[ "$(uname -m)" == arm64 ]] || fail 'This release requires Apple Silicon (M1 or later); Intel needs separate launcher and renderer builds.'
os=$(/usr/bin/sw_vers -productVersion)
[[ "${os%%.*}" -ge 15 ]] || fail 'The Metal renderer requires macOS 15 or later.'
for tool in curl shasum plutil ditto codesign spctl xargs tar; do command -v "$tool" >/dev/null || fail "Missing system tool: $tool"; done
game="$HOME/Library/Application Support/minecraft"
support="$HOME/Library/Application Support/tsmc.minecraft"
app="$HOME/Applications/Minecraft.app"
if [[ "$mode" == check ]]; then
    printf 'Supported Mac: %s, macOS %s\n' "$(uname -m)" "$os"
    for p in "$app" /Applications/Games/Minecraft.app /Applications/Minecraft.app "$game/home/Fabric 26.3" "$support/runtime/java-runtime-epsilon"; do
        [[ ! -e "$p" ]] || printf 'Already present (preserved): %s\n' "$p"
    done
    exit
fi
case "$release" in https://github.com/*/releases/download/*|/*) ;; *) fail 'Provide a pinned GitHub release URL or absolute local release directory.';; esac
release=${release%/}
if [[ "$mode" == dry ]]; then
    stage=$(mktemp -d "${TMPDIR:-/tmp}/minecraft-dry-run.XXXXXX")
else
    base="$HOME/Library/Caches/Minecraft-Setup"
    mkdir -p "$base/cache"
    available=$(df -Pk "$base" | awk 'NR==2 {print $4}')
    [[ "$available" -ge 3145728 ]] || fail 'At least 3 GiB of free disk space is required for downloads and staging.'
    cache="$base/cache"
    stage=$(mktemp -d "$base/stage.XXXXXX")
fi
printf 'Staging downloads in %s\n' "$stage"
# Retain staging on failures for diagnosis/resume through the content-addressed cache.
trap 'printf "Setup stopped; downloads are retained in %s\n" "$stage" >&2' ERR
asset() {
    local name="$1" expected="$2"
    if [[ "$release" == /* ]]; then cp "$release/$name" "$stage/$name"; else get "$release/$name" "$stage/$name"; fi
    [[ "$(hash 256 "$stage/$name")" == "$expected" ]] || fail "Release checksum mismatch: $name"
}
asset downloads.tsv '@downloads.tsv@'
asset runtime-links.tsv '@runtime-links.tsv@'
if [[ "$mode" == dry ]]; then
    report="$stage/availability.tsv"
    touch "$report"
    printf 'Checking all dependency URLs and release archives; no installation will occur.\n'
    {
        cat "$stage/downloads.tsv"
        printf '256\t%s\t644\t%s\t%s\n' '@settings.tar.gz@' settings.tar.gz '@RELEASE@/settings.tar.gz'
        printf '256\t%s\t644\t%s\t%s\n' '@Minecraft-arm64.zip@' Minecraft-arm64.zip '@RELEASE@/Minecraft-arm64.zip'
    } > "$stage/probes.tsv"
    # One curl process shares its connection pool across all upstream files.
    # Thousands of child curls caused a fresh TLS handshake for every asset.
    config="$stage/probes.curl"
    : > "$config"
    while IFS=$'\t' read -r algorithm expected permissions path url; do
        safe_path "$path"
        if ! resolved=$(resolve_url "$url" "$release" "$stage/resolve.json" 2> "$stage/resolve.error"); then
            reason=$(tr '\n\t' '  ' < "$stage/resolve.error" | cut -c 1-300)
            printf 'FAIL\t%s\t%s\t%s\n' "$path" "$url" "$reason" >> "$report"
            continue
        fi
        if [[ "$resolved" == /* ]]; then
            probe_row "$release" "$report" "$(printf '%s\t%s\t%s\t%s\t%s' "$algorithm" "$expected" "$permissions" "$path" "$resolved")" || true
            continue
        fi
        [[ "$resolved" == https://* ]] || fail "Non-HTTPS dependency: $path"
        case "$resolved$path" in *'"'*|*'\\'*|*$'\r'*|*$'\n'*) fail 'Unsafe curl configuration value';; esac
        # Options after --next are per-transfer; global parallel options remain active.
        if [[ -s "$config" ]]; then printf 'next\n' >> "$config"; fi
        printf 'url = "%s"\noutput = "/dev/null"\n' "$resolved" >> "$config"
        printf 'fail\nlocation\nhead\nsilent\nshow-error\nretry = 4\nretry-all-errors\nretry-max-time = 45\nconnect-timeout = 10\nmax-time = 30\nproto = "=https"\nproto-redir = "=https"\n' >> "$config"
        printf 'write-out = "%%{exitcode}\\t%%{http_code}\\t%s\\t%%{url_effective}\\t%%{errormsg}\\n"\n' "$path" >> "$config"
    done < "$stage/probes.tsv"
    result=0
    if [[ -s "$config" ]]; then
        /usr/bin/curl --parallel --parallel-max 4 --config "$config" > "$stage/remote-results.tsv" 2> "$stage/remote-errors.log" || result=$?
        awk -F '\t' 'BEGIN {OFS="\t"} {print ($1==0 && $2>=200 && $2<400 ? "OK" : "FAIL"), $3, $4, "curl=" $1 " http=" $2 " " $5}' "$stage/remote-results.tsv" >> "$report"
    fi
    passed=$(awk -F '\t' '$1=="OK" {n++} END {print n+0}' "$report")
    failed=$(awk -F '\t' '$1=="FAIL" {n++} END {print n+0}' "$report")
    total=$(wc -l < "$stage/probes.tsv" | tr -d ' ')
    printf 'Dry run: %s available, %s failed, %s expected. Report: %s\n' "$passed" "$failed" "$total" "$report"
    [[ "$result" -eq 0 && "$failed" -eq 0 && "$passed" -eq "$total" ]] || exit 1
    printf 'All URLs responded successfully. No game files, saves or settings were changed.\n'
    exit
fi
asset settings.tar.gz '@settings.tar.gz@'
asset Minecraft-arm64.zip '@Minecraft-arm64.zip@'
receipt='@downloads.tsv@:@settings.tar.gz@:@Minecraft-arm64.zip@'
if [[ "$mode" == install ]]; then
    if [[ -f "$game/home/Fabric 26.3/.setup-release" ]] && [[ "$(cat "$game/home/Fabric 26.3/.setup-release")" == "$receipt" ]] && [[ -d "$app" ]] && [[ -x "$support/runtime/java-runtime-epsilon/jre.bundle/Contents/Home/bin/java" ]]; then
        printf 'This release is already installed. Your settings and skins are unchanged.\n'; exit
    fi
    for p in "$game/home/Fabric 26.3" "$app" /Applications/Games/Minecraft.app /Applications/Minecraft.app; do
        [[ ! -e "$p" ]] || fail "Existing installation at $p. Preserved; use --download-only to stage this release for review."
    done
    custom=$(/usr/bin/defaults read tsmc.minecraft launcherWorkingDirectory 2>/dev/null || true)
    [[ -z "$custom" || "$custom" == "$game" ]] || fail "Launcher uses a custom working folder: $custom. Preserved."
fi
printf 'Downloading exact Minecraft, Fabric, Java and mod versions (4 parallel transfers)…\n'
tr '\n' '\0' < "$stage/downloads.tsv" | xargs -0 -P 4 -n 1 /bin/bash "$0" --fetch-row "$release" "$cache" "$stage"
while IFS=$'\t' read -r path target; do
    [[ -n "$path" ]] || continue
    safe_path "$path"
    [[ "$path" == runtime/* && "$target" != /* ]] || fail 'Invalid runtime link'
    mkdir -p "$stage/$(dirname "$path")"
    ln -s "$target" "$stage/$path"
done < "$stage/runtime-links.tsv"
# Archives are locally prepared and hash-pinned above, never arbitrary user archives.
tar -xzf "$stage/settings.tar.gz" -C "$stage"
/usr/bin/ditto -x -k "$stage/Minecraft-arm64.zip" "$stage/app"
/usr/bin/codesign --verify --deep --strict "$stage/app/Minecraft.app"
"$stage/runtime/jre.bundle/Contents/Home/bin/java" -version
if [[ "$mode" == download ]]; then
    printf 'Downloaded and verified. Staged setup: %s\nNo installed files were changed.\n' "$stage"; exit
fi
/usr/sbin/spctl --assess --type execute "$stage/app/Minecraft.app" || fail 'The launcher needs Developer ID signing and notarization before unattended installation. The installer does not bypass Gatekeeper.'
# Check conflicts before writing any shared libraries or metadata.
while IFS= read -r -d '' src; do
    rel=${src#"$stage/game/"}
    if [[ -e "$game/$rel" ]]; then
        [[ -f "$game/$rel" && ! -L "$game/$rel" ]] && cmp -s "$src" "$game/$rel" || fail "Existing file differs: $game/$rel"
    fi
done < <(find "$stage/game" -type f -print0)
[[ ! -e "$support/runtime/java-runtime-epsilon" ]] || fail 'A Java runtime already exists. Preserved; review the staged installation first.'
mkdir -p "$game" "$support/runtime" "$HOME/Applications"
# The selected instance and app are absent; shared official files were compared above.
/usr/bin/ditto "$stage/game" "$game"
mv "$stage/runtime" "$support/runtime/java-runtime-epsilon"
mv "$stage/app/Minecraft.app" "$app"
printf '%s\n' "$receipt" > "$game/home/Fabric 26.3/.setup-release"
printf '\nInstalled: %s\nOpen it and add your own player once. Later launches start Minecraft directly.\nUse a different player name from the host.\n' "$app"
