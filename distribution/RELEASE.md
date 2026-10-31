# Release steps

The source preparation and finalization scripts are local-only. Publishing is a separate, explicitly approved action.

For the ad-hoc distribution route, keep the project's valid ad-hoc signature and pass `--allow-adhoc` to `finalize-release.sh` and the recipient's installer. Steps 2–3 below apply only to Developer ID distribution. Ad-hoc signing needs no paid account, but it does not provide Apple notarization or publisher identity verification. The scripts do not change macOS security policy.

1. Build the committed launcher with `build-launcher.sh /absolute/output-directory`. Build the committed shader revision in an isolated checkout with its Gradle wrapper and JDK 25. Keep the corresponding source archives and revision IDs.
2. Prepare a Developer ID Application signed launcher with Hardened Runtime. This launcher embeds Java in its process, so its distribution entitlements must support HotSpot JIT and loading independently signed Java/mod native libraries. Sign nested Sparkle executables, XPC services, helper apps and frameworks inside-out before the main app; preserve each component's appropriate entitlements. Do not use `codesign --deep` for signing.
3. When external notarization is authorized, submit with `xcrun notarytool`, inspect the result, and staple the accepted ticket. No notarization upload is performed by these scripts.
4. Resolve exact mod files using `resolve-mods.py`. Verify any explicit bundled mod's redistribution notices before selecting it with `--bundled-mod`; automatic rehosting of unresolved files is intentionally not supported.
5. Run `finalize-release.sh` with the signed/stapled app, official Java manifest, rebuilt shader JAR and proposed versioned shader URL. This verifies the signature and ticket, creates the assets, and records their hashes.
6. Review release notes, source revisions, artifacts and target repositories. Publish only after explicit authorization. Run the public `--dry-run` and test the complete installation on a fresh Mac before sharing the command.

Proposed repository split:

- `metalnakls/minecraft`: launcher ZIP, installer, manifests, settings archive, modified Mac input-fix JAR and its notices, launcher source archive, checksums and optional skin helper.
- `metalnakls/minecraftmetalshaders`: shader JAR, matching source archive, checksums and release notes.

The one-command install downloads the versioned script to a temporary file and then runs it with the same pinned release URL. It does not pipe into bash because download workers need a real script path. Add `--dry-run` to check availability without installation.

MCUI's launch-time updater is enabled by default in launcher 1.3.6+. Future stable MCUI releases should contain `mcui-VERSION.jar`, with an incremented version and accurate dependency predicates in `fabric.mod.json`; GitHub supplies the asset SHA-256 digest. No separate update manifest is required. Unsupported dependency expressions are rejected rather than assumed compatible. Metal Shaders uses the same checks against metalnakls/minecraftmetalshaders, with backups in .shader-backups. Both toggles default to on; other mods remain pinned.

Do not publish generated settings or player skin files without reviewing them. Saves and credentials are excluded by the builder, but the chosen controls, visual preferences and skin artwork are intentional shared content.

Launcher 1.3.7 adds shader checks before each launch, verifying the fork asset digest, mod ID, dependencies and declared conflicts. Alpha version numbers and Fabric tilde ranges are supported. Settings and saves are preserved.

Before publishing an archive, run `bash distribution/verify-launcher.sh APP JAVA_EXECUTABLE`. This starts Java through the actual release executable and checks the layered Icon Composer variants. Java re-enters the executable through `dlsym("main")`; Release must export `_main` and use `STRIP_STYLE = non-global`. A successful archive or an unstripped debug run alone does not verify this path.
