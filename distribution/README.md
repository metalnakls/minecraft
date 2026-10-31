# Local distribution preparation

This tooling prepares a pinned Minecraft 26.3 / Fabric 0.19.5 setup for Apple Silicon Macs running macOS 15 or later. It never publishes a release, pushes Git, or changes network settings.

The recipient needs only built-in macOS tools. Preparation uses Python 3, Git, and Xcode. Downloaded Minecraft, Java, Fabric and third-party mods stay on their original hosts. The launcher, forked shader build, settings snapshot and explicitly selected locally modified mods become release assets.

Launcher 1.3.6 checks `metalnakls/MCUI` for stable updates before every game launch, enabled by default. It verifies GitHub's SHA-256 digest and the Fabric dependency predicates, backs up the installed JAR under `.mcui-backups`, then atomically replaces that same filename before Java starts. Settings and saves are untouched. Offline, incompatible or unverified updates leave the existing mod installed. Other mods and shaders remain pinned.

Hold Option while opening Minecraft to show the launcher, then use Settings → General → Update MCUI automatically to turn checks off. No update code runs in other launchers. Run `swift test` from the repository root for isolated updater tests; `MCUI_LIVE_TEST=1 swift test --filter liveGitHubUpdateInTemporaryInstance` tests the public release in a temporary instance without starting Minecraft.

```sh
python3 prepare.py --java-manifest /path/to/java-runtime-manifest.json \
  --app /path/to/Minecraft.app \
  --shader-jar /path/to/metal-1.2.6-alpha.jar \
  --bundled-mod 'macos-input-fixes-1.13+26.3.jar'
python3 resolve-mods.py
# Repeat preparation with --require-resolved once all upstream hashes resolve.
bash release/install.sh --local-release "$PWD/release" --dry-run
```

`--dry-run` retrieves only small manifests, checks payload URLs with HEAD requests, reports curl/HTTP errors, and exits nonzero if any checks fail or are incomplete. It pools connections and retries transient TLS failures with a bounded retry budget. It does not verify remote payload hashes; `--download-only` and installation download and verify them. To use a published release, replace `--local-release` with `--release https://github.com/metalnakls/minecraft/releases/download/TAG`.

`--check` reports platform support and existing installs. Installation preserves existing apps/profiles rather than replacing them. `--download-only` prepares staging without modifying game files. The initial player setup is per person; accounts are never shared. A completed install can be rerun without resetting settings.

The builder reads only approved config files, options, skin PNGs, active mod JARs and version metadata. **It never reads or packages saves.** Accounts, launcher preferences/databases, server lists, screenshots, logs, controller identities and world/map caches are excluded. Generated machine-specific bundles, inventories, build output and resolved locks are gitignored.

To refresh current settings in an already prepared release, add `--settings-only` to `prepare.py`. This preserves the pinned binaries, download lock and version metadata while regenerating the settings archive, installer hashes and checksums.

The deliberately ad-hoc signed launcher can be installed with `--allow-adhoc`. This retains hash and signature checks, but does not require a Developer ID identity or notarization. It does not locally notarize, re-sign downloaded code, remove quarantine or disable Gatekeeper. macOS may still require the user to approve the app with Open Anyway. The app is already ad-hoc signed at build time, so signing it again on the recipient's device is unnecessary.

For LAN skins, install both players' PNGs on both Macs:

```sh
bash install-skin.sh ExactPlayerName /path/to/skin.png
```

Use distinct player names, repeat for each player and restart Minecraft. The skins go into `CustomSkinLoader/LocalSkin/skins` in the `Fabric 26.3` profile. Local skins are not automatically sent to other players.

Test the real downloader's handling of a dropped TLS handshake with `python3 test_transport.py`. It creates an ephemeral localhost certificate trusted only by the test process; it changes no system trust or proxy settings. It proves the original downloader fails and the updated downloader retries and checks the file hash.
