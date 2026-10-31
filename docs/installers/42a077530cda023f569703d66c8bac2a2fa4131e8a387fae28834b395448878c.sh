#!/bin/bash
# Generated release installer. macOS ships every command used here; no brew/python/jq.
set -euo pipefail
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
hash() { /usr/bin/shasum -a "$1" "$2" | /usr/bin/awk '{print $1}'; }
get() { /usr/bin/curl --fail --location --silent --show-error --retry 4 --retry-all-errors --retry-max-time 90 --connect-timeout 10 --max-time 300 --proto '=https' --proto-redir '=https' "$1" -o "$2"; }
safe_path() { case "$1" in ''|/*|../*|*/../*|*/..|*\\*) fail "Unsafe path: $1";; esac; }

# Preserve partial bytes between attempts and invocations; promote only verified data.
download_verified() {
    local url="$1" dest="$2" algorithm="$3" expected="$4" attempt status http part="$2.part" delay
    if [[ -f "$dest" ]] && [[ "$(hash "$algorithm" "$dest")" == "$expected" ]]; then return; fi
    for attempt in 1 2 3 4; do
        if [[ -f "$part" ]] && [[ "$(hash "$algorithm" "$part")" == "$expected" ]]; then mv -f "$part" "$dest"; return; fi
        status=0; http=''
        if [[ "$url" == /* ]]; then
            cp "$url" "$part" || status=$?
        else
            http=$(/usr/bin/curl --fail --location --silent --show-error --continue-at - \
                --connect-timeout 20 --max-time 300 --speed-limit 1024 --speed-time 45 \
                --proto '=https' --proto-redir '=https' "$url" -o "$part" --write-out '%{http_code}') || status=$?
        fi
        if [[ "$status" -eq 0 ]]; then
            if [[ "$(hash "$algorithm" "$part")" == "$expected" ]]; then mv -f "$part" "$dest"; return; fi
            printf 'Checksum mismatch; retrying a fresh download: %s\n' "$url" >&2
            rm -f "$part"
        elif [[ "$status" -eq 33 || "$status" -eq 36 || "$http" == 416 ]]; then
            # Some servers do not accept byte ranges. Restart only this file.
            printf 'Server cannot resume this file; restarting it: %s\n' "$url" >&2
            rm -f "$part"
        fi
        if [[ "$attempt" -lt 4 ]]; then
            delay=$((attempt * 2))
            printf 'Retry %s/4 in %ss (partial download retained): %s\n' "$((attempt+1))" "$delay" "$url" >&2
            sleep "$delay"
        fi
    done
    printf 'Download paused: %s\nRerun the same install command to resume.\n' "$url" >&2
    return 1
}
record_progress() {
    [[ -z "${MC_SETUP_PROGRESS:-}" ]] || printf '%s\t%s\n' "$1" "$2" >> "$MC_SETUP_PROGRESS"
}
verify_app() {
    local target="$1" adhoc="$2" signature
    /usr/bin/codesign --verify --deep --strict "$target" || return 1
    if [[ "$adhoc" == true ]]; then
        signature=$(/usr/bin/codesign -dv "$target" 2>&1) || { printf '%s\n' "$signature" >&2; return 1; }
        # No early-closing pipe: grep -q could SIGPIPE a valid codesign process.
        grep -q '^Signature=adhoc$' <<< "$signature" || fail 'Expected the explicitly selected ad-hoc build.'
    else
        /usr/sbin/spctl --assess --type execute "$target" || return 1
    fi
}
stop_children() {
    local parent="$1" child
    for child in $(/usr/bin/pgrep -P "$parent" 2>/dev/null || true); do
        stop_children "$child"
        kill "$child" 2>/dev/null || true
    done
}
finish_setup() {
    local status=$?
    trap - EXIT INT TERM
    stop_children "$$"
    if [[ -n "${setup_lock:-}" ]]; then rm -rf "$setup_lock"; fi
    if [[ "$status" -ne 0 ]]; then
        printf '\nSetup paused. Verified files and partial downloads are retained in %s\nRerun the same command to resume; matching files will be skipped.\n' "$base" >&2
    fi
    exit "$status"
}
show_progress() {
    local active part path bytes
    awk -F '\t' -v total="$total" '
      {n++; count[$1]++}
      END {printf "Progress: %d/%d files | %d reused from installation | %d cached/staged | %d downloaded\n", n,total,count["reused"],count["cached"],count["downloaded"]}' "$MC_SETUP_PROGRESS"
    for active in "$stage"/active.*; do
        [[ -f "$active" ]] || continue
        IFS=$'\t' read -r part path < "$active" || continue
        bytes=0
        [[ ! -f "$part" ]] || bytes=$(stat -f %z "$part" 2>/dev/null || printf 0)
        printf '  Downloading/resuming: %s (%s bytes received)\n' "$path" "$bytes"
    done
}

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
    local algorithm expected mode path url cached tmp key installed='' alternate origin=cached
    IFS=$'\t' read -r algorithm expected mode path url <<< "$row"
    safe_path "$path"
    case "$algorithm" in 1|256) ;; *) fail 'Invalid hash algorithm';; esac
    case "$mode" in 644|755) ;; *) fail 'Invalid permissions';; esac
    [[ "$expected" =~ ^[0-9a-f]+$ ]] || fail 'Invalid digest'
    mkdir -p "$stage/$(dirname "$path")"
    case "$path" in
        game/*) [[ -z "${MC_SETUP_EXISTING_GAME:-}" ]] || installed="$MC_SETUP_EXISTING_GAME/${path#game/}";;
        runtime/*) [[ -z "${MC_SETUP_EXISTING_RUNTIME:-}" ]] || installed="$MC_SETUP_EXISTING_RUNTIME/${path#runtime/}";;
    esac
    if [[ -n "$installed" && -f "$installed" && ! -L "$installed" ]] && [[ "$(hash "$algorithm" "$installed")" == "$expected" ]]; then
        cp "$installed" "$stage/$path"; chmod "$mode" "$stage/$path"
        record_progress reused "$path"; return
    fi
    # A matching mod may already have a different filename.
    case "$path" in
        game/home/*/mods/*.jar)
            if [[ -n "$installed" ]]; then
                for alternate in "$(dirname "$installed")"/*.jar; do
                    [[ -f "$alternate" && ! -L "$alternate" && "$alternate" != "$installed" ]] || continue
                    if [[ "$(hash "$algorithm" "$alternate")" == "$expected" ]]; then
                        cp "$alternate" "$stage/$path"; chmod "$mode" "$stage/$path"
                        record_progress reused "$path"; return
                    fi
                done
            fi;;
    esac
    if [[ -f "$stage/$path" ]] && [[ "$(hash "$algorithm" "$stage/$path")" == "$expected" ]]; then
        chmod "$mode" "$stage/$path"; record_progress cached "$path"; return
    fi
    cached="$cache/$algorithm-$expected"
    if [[ ! -f "$cached" ]] || [[ "$(hash "$algorithm" "$cached")" != "$expected" ]]; then
        # Include the target path: duplicate manifest hashes can download in parallel.
        key=$(printf '%s' "$path" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
        tmp="$cache/$algorithm-$expected-$key.download"
        printf '%s\t%s\n' "$tmp.part" "$path" > "$stage/active.$key"
        if [[ -f "$tmp" ]] && [[ "$(hash "$algorithm" "$tmp")" == "$expected" ]]; then
            :
        else
            url=$(resolve_url "$url" "$release" "$tmp.json") || fail "Cannot resolve exact mod: $path"
            download_verified "$url" "$tmp" "$algorithm" "$expected" || return 1
        fi
        mv -f "$tmp" "$cached"
        rm -f "$stage/active.$key" "$tmp.json"
        origin=downloaded
    fi
    cp "$cached" "$stage/$path"; chmod "$mode" "$stage/$path"
    record_progress "$origin" "$path"
}

# Reject links and file/directory collisions before following destination paths.
check_destination() {
    local dest="$1" parent
    [[ ! -L "$dest" ]] || fail "Destination is a symbolic link: $dest"
    parent=$(dirname "$dest")
    while [[ "$parent" != / ]]; do
        [[ ! -L "$parent" && ( ! -e "$parent" || -d "$parent" ) ]] || fail "Unsafe destination parent: $parent"
        parent=$(dirname "$parent")
    done
}
ensure_backup() {
    if [[ -z "${backup:-}" ]]; then
        mkdir -p "${backup_root:-$base/backups}"
        backup=$(mktemp -d "${backup_root:-$base/backups}/installation.XXXXXX")
        printf 'Backing up replaced files in %s\n' "$backup"
    fi
}
backup_file() {
    local src="$1" rel="$2"
    ensure_backup
    mkdir -p "$backup/$(dirname "$rel")"
    cp -p "$src" "$backup/$rel"
    cmp -s "$src" "$backup/$rel" || fail "Backup verification failed: $src"
}
mod_id() {
    /usr/bin/unzip -p "$1" fabric.mod.json 2>/dev/null | /usr/bin/plutil -extract id raw -o - - 2>/dev/null
}
merge_game() {
    local applied=0 src rel dest tmp id other other_id mods="$game/home/Fabric 26.3/mods"
    # Validate every destination before modifying any game file.
    while IFS= read -r -d '' src; do
        rel=${src#"$stage/game/"}; dest="$game/$rel"
        check_destination "$dest"
        [[ ! -e "$dest" || -f "$dest" ]] || fail "Expected a file: $dest"
    done < <(find "$stage/game" -type f -print0)
    if [[ -d "$mods" ]]; then
        while IFS= read -r -d '' other; do
            check_destination "$other"
            [[ -f "$other" ]] || fail "Expected a mod file: $other"
        done < <(find "$mods" -maxdepth 1 -name '*.jar' -print0)
    fi
    while IFS= read -r -d '' src; do
        rel=${src#"$stage/game/"}; dest="$game/$rel"
        applied=$((applied+1))
        if [[ "$((applied % 250))" -eq 1 ]]; then printf 'Applying/reusing game files: %s checked\n' "$applied"; fi
        # Existing player preferences, skins and worlds belong to this Mac.
        case "$rel" in
            home/*/config/*|home/*/options.txt|home/*/CustomSkinLoader/*)
                [[ ! -e "$dest" ]] || continue;;
            home/*/saves/*|home/*/screenshots/*|home/*/logs/*|home/*/servers.dat|home/*/usercache.json)
                fail "Private data must not be in the setup: $rel";;
        esac
        case "$rel" in
            home/*/mods/*.jar)
                id=$(mod_id "$src") || fail "Cannot identify bundled mod: $rel"
                for other in "$mods"/*.jar; do
                    [[ -f "$other" && "$other" != "$dest" ]] || continue
                    other_id=$(mod_id "$other" || true)
                    if [[ "$other_id" == "$id" || ( "$id" == mcopt-metal && "$other_id" == sodium ) ]]; then
                        backup_file "$other" "game/${other#"$game/"}"
                        rm "$other"
                        if [[ "$other_id" == sodium && "$id" == mcopt-metal ]]; then
                            printf 'Disabled Sodium (incompatible with Metal Shaders): %s\nBackup: %s/game/%s\n' "$other" "$backup" "${other#"$game/"}"
                        fi
                    fi
                done;;
        esac
        if [[ -f "$dest" ]]; then
            cmp -s "$src" "$dest" && continue
            backup_file "$dest" "game/$rel"
        fi
        mkdir -p "$(dirname "$dest")"
        tmp=$(mktemp "$(dirname "$dest")/.setup.XXXXXX")
        cp -p "$src" "$tmp"
        mv -f "$tmp" "$dest"
    done < <(find "$stage/game" -type f -print0)
}
replace_directory() {
    local src="$1" dest="$2" label="$3" previous=''
    check_destination "$dest"
    [[ ! -e "$dest" || -d "$dest" ]] || fail "Expected a directory: $dest"
    if [[ -d "$dest" ]]; then
        if diff -qr "$src" "$dest" >/dev/null; then
            printf 'Reusing matching installation: %s\n' "$dest"
            return 0
        fi
        ensure_backup
        previous="$backup/$label"
        mv "$dest" "$previous"
    fi
    mkdir -p "$(dirname "$dest")"
    if ! mv "$src" "$dest"; then
        [[ -z "$previous" ]] || mv "$previous" "$dest"
        fail "Could not install $dest; previous installation restored."
    fi
}

if [[ "${1:-}" == --fetch-row ]]; then shift; fetch_row "$@"; exit; fi
if [[ "${1:-}" == --probe-row ]]; then shift; probe_row "$@"; exit; fi

usage() {
    cat <<'EOF'
Usage: bash install.sh --check
       bash install.sh --release https://github.com/OWNER/REPO/releases/download/TAG [--dry-run|--download-only]
       bash install.sh --local-release /absolute/path/to/release [--dry-run|--download-only]

Installs the pinned Apple Silicon setup into ~/Applications/Minecraft.app and
~/Library/Application Support/minecraft. Reuses existing files and preserves
player settings, skins, accounts and saves. Replaced files are backed up. No sudo, firewall changes, account copying or auto-launch.
--dry-run downloads only small manifests into a temporary folder and checks all
remote URLs with HEAD requests. It does not install files or change settings.
URL availability is not a checksum check; installation verifies every download.
--allow-adhoc explicitly permits the ad-hoc signed release without requiring
Apple notarization. Hash and signature checks remain mandatory. This does not
notarize locally, remove quarantine, or change Gatekeeper settings.
EOF
}
release=''; mode=install; allow_adhoc=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) mode=check; shift;;
        --dry-run) mode=dry; shift;;
        --allow-adhoc) allow_adhoc=true; shift;;
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
for tool in curl shasum plutil ditto codesign spctl xargs tar unzip; do command -v "$tool" >/dev/null || fail "Missing system tool: $tool"; done
game="$HOME/Library/Application Support/minecraft"
support="$HOME/Library/Application Support/tsmc.minecraft"
backup_root="$HOME/Library/Application Support/Minecraft-Setup/backups"
app="$HOME/Applications/Minecraft.app"
custom=$(/usr/bin/defaults read tsmc.minecraft launcherWorkingDirectory 2>/dev/null || true)
if [[ -n "$custom" ]]; then
    [[ "$custom" == /* ]] || fail "Invalid launcher working folder: $custom"
    game="$custom"
fi
for candidate in "$app" /Applications/Games/Minecraft.app /Applications/Minecraft.app; do
    if [[ -d "$candidate" ]] && [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)" == tsmc.minecraft ]]; then
        app="$candidate"; break
    fi
done
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
    setup_lock="$base/setup.lock"
    if ! mkdir "$setup_lock" 2>/dev/null; then
        owner=$(cat "$setup_lock/pid" 2>/dev/null || true)
        if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$setup_lock"
            mkdir "$setup_lock" || fail 'Another setup is starting; retry shortly.'
        else
            fail 'Another setup is running. Wait for it or stop it before resuming.'
        fi
    fi
    printf '%s\n' "$$" > "$setup_lock/pid"
    trap finish_setup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stage="$base/stage-f848a0add62c1749922f8145d4c54948d471149a0efb1d6af8f8b4ed2e3bc134"
    mkdir -p "$stage"
    rm -f "$stage"/active.*
fi
printf 'Staging downloads in %s\n' "$stage"
# Retain staging on failures for diagnosis/resume through the content-addressed cache.
if [[ "$mode" == dry ]]; then
    trap 'printf "URL check stopped; report retained in %s\n" "$stage" >&2' ERR
fi
asset() {
    local name="$1" expected="$2" previous
    if [[ -f "$stage/$name" ]] && [[ "$(hash 256 "$stage/$name")" == "$expected" ]]; then
        printf 'Reusing verified release file: %s\n' "$name"; return
    fi
    if [[ "$mode" != dry ]]; then
        # Import verified release archives retained by older installer attempts.
        for previous in "$base"/stage.*/"$name"; do
            [[ -f "$previous" ]] || continue
            if [[ "$(hash 256 "$previous")" == "$expected" ]]; then
                cp "$previous" "$stage/$name"
                printf 'Reusing previous download: %s\n' "$name"; return
            fi
        done
    fi
    printf 'Downloading/resuming release file: %s\n' "$name"
    download_verified "$release/$name" "$stage/$name" 256 "$expected" || fail "Release download paused: $name"
}
asset downloads.tsv 'f848a0add62c1749922f8145d4c54948d471149a0efb1d6af8f8b4ed2e3bc134'
asset runtime-links.tsv 'c3805bf392bbefd4f86a9563dea5b6329828267c504f901597b0f20e029bc6cb'
if [[ "$mode" == dry ]]; then
    report="$stage/availability.tsv"
    touch "$report"
    printf 'Checking all dependency URLs and release archives; no installation will occur.\n'
    {
        cat "$stage/downloads.tsv"
        printf '256\t%s\t644\t%s\t%s\n' '5fc36e5e826b3a3c63aaf14ee12d543f908f343e348c8b048d140f0c90a76b41' settings.tar.gz '@RELEASE@/settings.tar.gz'
        printf '256\t%s\t644\t%s\t%s\n' '0ed16a1d1a43f63ed2b095cc787d296c201ac72f71cb0c8b3eb133429214f797' Minecraft-arm64.zip '@RELEASE@/Minecraft-arm64.zip'
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
asset settings.tar.gz '5fc36e5e826b3a3c63aaf14ee12d543f908f343e348c8b048d140f0c90a76b41'
asset Minecraft-arm64.zip '0ed16a1d1a43f63ed2b095cc787d296c201ac72f71cb0c8b3eb133429214f797'
receipt='f848a0add62c1749922f8145d4c54948d471149a0efb1d6af8f8b4ed2e3bc134:5fc36e5e826b3a3c63aaf14ee12d543f908f343e348c8b048d140f0c90a76b41:0ed16a1d1a43f63ed2b095cc787d296c201ac72f71cb0c8b3eb133429214f797'
if [[ "$mode" == install ]]; then
    for p in "$game/home/Fabric 26.3" "$support/runtime/java-runtime-epsilon" "$app"; do
        check_destination "$p"
        [[ ! -e "$p" || -d "$p" ]] || fail "Expected a directory: $p"
    done
    if [[ -e "$app" ]] && [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)" != tsmc.minecraft ]]; then
        fail "Another application occupies $app; it has been preserved."
    fi
    printf 'Using installation folder: %s\n' "$game"
fi
printf 'Checking installed files and cached downloads; fetching only missing or changed files…\n'
export MC_SETUP_EXISTING_GAME="$game"
export MC_SETUP_EXISTING_RUNTIME="$support/runtime/java-runtime-epsilon"
export MC_SETUP_PROGRESS="$stage/progress.tsv"
: > "$MC_SETUP_PROGRESS"
total=$(wc -l < "$stage/downloads.tsv" | tr -d ' ')
tr '\n' '\0' < "$stage/downloads.tsv" | xargs -0 -P 4 -n 1 /bin/bash "$0" --fetch-row "$release" "$cache" "$stage" &
workers=$!
while kill -0 "$workers" 2>/dev/null; do
    show_progress
    sleep 2
done
status=0
wait "$workers" || status=$?
show_progress
[[ "$status" -eq 0 ]] || fail 'Some downloads are incomplete. Rerun the same command to resume.'
while IFS=$'\t' read -r path target; do
    [[ -n "$path" ]] || continue
    safe_path "$path"
    [[ "$path" == runtime/* && "$target" != /* ]] || fail 'Invalid runtime link'
    mkdir -p "$stage/$(dirname "$path")"
    if [[ -L "$stage/$path" && "$(readlink "$stage/$path")" == "$target" ]]; then continue; fi
    [[ ! -e "$stage/$path" && ! -L "$stage/$path" ]] || fail "Unexpected runtime link destination: $path"
    ln -s "$target" "$stage/$path"
done < "$stage/runtime-links.tsv"
# Archives are locally prepared and hash-pinned above, never arbitrary user archives.
tar -xzf "$stage/settings.tar.gz" -C "$stage"
/usr/bin/ditto -x -k "$stage/Minecraft-arm64.zip" "$stage/app"
printf 'Verifying launcher signature and Java…\n'
/usr/bin/codesign --verify --deep --strict "$stage/app/Minecraft.app"
"$stage/runtime/jre.bundle/Contents/Home/bin/java" -version
if [[ "$mode" == download ]]; then
    printf 'Downloaded and verified. Staged setup: %s\nNo installed files were changed.\n' "$stage"; exit
fi
verify_app "$stage/app/Minecraft.app" "$allow_adhoc" || fail 'Launcher signature verification failed.'
if [[ "$allow_adhoc" == true ]]; then
    printf 'Installing an ad-hoc signed build: no Developer ID or Apple notarization. macOS may require Open Anyway.\n'
fi
printf 'Applying verified files; preserving player data and backing up replacements…\n'
backup=''
merge_game
replace_directory "$stage/runtime" "$support/runtime/java-runtime-epsilon" runtime
replace_directory "$stage/app/Minecraft.app" "$app" Minecraft.app
check_destination "$game/home/Fabric 26.3/.setup-release"
printf '%s\n' "$receipt" > "$game/home/Fabric 26.3/.setup-release"
printf '\nInstalled: %s\nOpen it and add your own player once. Later launches start Minecraft directly.\nUse a different player name from the host.\n' "$app"
