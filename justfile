# Zephr build & release pipeline. `just` lists recipes.
#
# Local:    just test build run
# Ship:     just archive export dmg notarize   (needs Developer ID; see
#           `just notary-setup` once for credentials)
# Quick:    just app dmg                       (dev-signed DMG for yourself)
#
# Signing:  DEVELOPMENT_TEAM in the project file is a personal team ID.
#           Override it per-invocation instead of editing the project:
#             DEVELOPMENT_TEAM=ABCDE12345 just build
#             DEVELOPMENT_TEAM=ABCDE12345 just app dmg
#           Left unset, it's passed through empty, which lets Xcode fall
#           back to automatic/ad-hoc local signing.

set shell := ["bash", "-euo", "pipefail", "-c"]

project := "Zephr.xcodeproj"
scheme := "Zephr"
dist := "dist"
build_dir := "build"
version := `awk '/MARKETING_VERSION/{mv=$0} /name = Release;/{if(mv){sub(/.*= /,"",mv);sub(/;.*/,"",mv);print mv;exit}} END{if(!mv){print "no MARKETING_VERSION found in project.pbxproj" > "/dev/stderr"; exit 1}}' Zephr.xcodeproj/project.pbxproj`
archive := dist / "Zephr.xcarchive"
dmg_file := dist / "Zephr-" + version + ".dmg"
notary_profile := "zephr-notary"

# List available recipes.
default:
    @just --list --unsorted

# Run the ZephrCore engine test suite (fast, no permissions needed).
test:
    swift test --package-path ZephrCore

# Debug build.
build:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug \
        build DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" -quiet

# Build Debug and launch it.
run: build
    open "$(xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3; exit}')/{{scheme}}.app"

# Release build → dist/Zephr.app (signed with your development identity).
app:
    rm -rf {{dist}}/{{scheme}}.app
    mkdir -p {{dist}}
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        -derivedDataPath {{build_dir}} build DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" -quiet
    cp -R {{build_dir}}/Build/Products/Release/{{scheme}}.app {{dist}}/
    @echo "→ {{dist}}/{{scheme}}.app"

# Archive for distribution.
archive:
    mkdir -p {{dist}}
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        archive -archivePath {{archive}} DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" -quiet
    @echo "→ {{archive}}"

# Export a Developer ID–signed app from the archive → dist/Zephr.app.
export:
    rm -rf {{dist}}/{{scheme}}.app
    xcodebuild -exportArchive -archivePath {{archive}} \
        -exportOptionsPlist tools/ExportOptions.plist \
        -exportPath {{dist}} -quiet
    codesign --verify --strict {{dist}}/{{scheme}}.app
    # spctl exits 3 for a Developer ID app that is not notarized yet, which
    # is exactly what this step produces — notarization is two steps later.
    # Under `set -o pipefail` the pipeline inherits that 3 even when grep
    # matched, so capture the output first and test it, never the status.
    assessment="$(spctl -a -vv -t exec {{dist}}/{{scheme}}.app 2>&1 || true)"; \
    case "$assessment" in *"Developer ID"*) ;; *) echo "REFUSING: {{dist}}/{{scheme}}.app is not Developer ID signed"; echo "$assessment"; exit 1;; esac
    @echo "→ {{dist}}/{{scheme}}.app (Developer ID)"

# Verify release invariants: App Sandbox stays off, Hardened Runtime is on,
# and no private/undocumented APIs crept into the sources.
verify:
    test -d {{dist}}/{{scheme}}.app || { echo "no {{dist}}/{{scheme}}.app to verify — run 'just export' first"; exit 1; }
    if codesign -d --entitlements :- {{dist}}/{{scheme}}.app 2>/dev/null | grep -q "app-sandbox"; then echo "REFUSING: app-sandbox entitlement present in {{dist}}/{{scheme}}.app"; exit 1; fi
    # codesign renders the flag bitfield with every flag set, e.g.
    # `flags=0x10002(adhoc,runtime)` — match the named flag, not one literal.
    if ! codesign -d -v {{dist}}/{{scheme}}.app 2>&1 | grep -qE "flags=0x[0-9a-f]+\(([a-z-]+,)*runtime[,)]"; then echo "REFUSING: hardened runtime not enabled on {{dist}}/{{scheme}}.app"; exit 1; fi
    just lint
    @echo "→ verify OK: no App Sandbox, Hardened Runtime on, no private APIs"

# Public-APIs-only guard (§6.1). A release gate is too late for this — it
# runs in CI so a pull request cannot land a private call in the first place.
lint:
    if grep -rEn "SkyLight|CGSDefaultConnection|_AXUIElementGetWindow|dlsym|@_silgen_name" Zephr/ ZephrCore/Sources/; then echo "REFUSING: private API pattern found in sources (see matches above)"; exit 1; fi
    @echo "→ lint OK: public APIs only"

# Package dist/Zephr.app into a drag-to-Applications DMG.
dmg:
    test -d {{dist}}/{{scheme}}.app || { echo "no {{dist}}/{{scheme}}.app — run 'just app' (dev) or 'just archive export' (Developer ID) first"; exit 1; }
    codesign --verify --strict {{dist}}/{{scheme}}.app
    rm -rf {{dist}}/staging {{dmg_file}}
    mkdir -p {{dist}}/staging
    cp -R {{dist}}/{{scheme}}.app {{dist}}/staging/
    ln -s /Applications {{dist}}/staging/Applications
    hdiutil create -volname "Zephr {{version}}" -srcfolder {{dist}}/staging \
        -ov -format UDZO {{dmg_file}} -quiet
    rm -rf {{dist}}/staging
    @echo "→ {{dmg_file}}"

# One-time: store notarization credentials in the keychain.
# Needs an app-specific password from appleid.apple.com → Sign-In & Security.
notary-setup:
    xcrun notarytool store-credentials {{notary_profile}}

# Notarize the DMG and staple the ticket (requires `just notary-setup` once).
notarize:
    test -f {{dmg_file}} || { echo "no {{dmg_file}} — run 'just dmg' first"; exit 1; }
    xcrun notarytool submit {{dmg_file}} --keychain-profile {{notary_profile}} --wait
    xcrun stapler staple {{dmg_file}}
    xcrun stapler validate {{dmg_file}}
    @echo "→ {{dmg_file}} notarized and stapled"

# Refuse to release from a dirty working tree.
check-clean:
    git diff --quiet && git diff --cached --quiet || { echo "REFUSING: working tree is dirty — commit or stash before releasing"; exit 1; }

# Full release pipeline: archive → export → verify → dmg → notarize.
release: check-clean archive export verify dmg notarize

# Bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in both the Debug and
# Release target configs, e.g. `just bump 0.2.0`.
bump to:
    #!/usr/bin/env bash
    set -euo pipefail
    cur=$(awk -F' = |;' '/CURRENT_PROJECT_VERSION/{print $2; exit}' {{project}}/project.pbxproj)
    next=$((cur + 1))
    sed -i '' -E 's/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = {{to}};/g' {{project}}/project.pbxproj
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${next};/g" {{project}}/project.pbxproj
    echo "→ MARKETING_VERSION={{to}}  CURRENT_PROJECT_VERSION=${next}"

# Copy dist/Zephr.app into /Applications (quits a running instance first).
install:
    test -d {{dist}}/{{scheme}}.app || { echo "no {{dist}}/{{scheme}}.app — run 'just app' first"; exit 1; }
    -pkill -TERM -x {{scheme}} 2>/dev/null; sleep 1
    rm -rf "/Applications/{{scheme}}.app.new"
    ditto {{dist}}/{{scheme}}.app "/Applications/{{scheme}}.app.new"
    rm -rf /Applications/{{scheme}}.app
    mv "/Applications/{{scheme}}.app.new" /Applications/{{scheme}}.app
    open /Applications/{{scheme}}.app

# Regenerate the app icon assets from tools/make-icon.swift.
icon:
    swift tools/make-icon.swift

# Install the zephrctl CLI to /usr/local/bin.
cli:
    sudo install -m 0755 tools/zephrctl /usr/local/bin/zephrctl
    @echo "→ /usr/local/bin/zephrctl"

# What CI's core-tests job runs.
# CI runs the suite warning-clean; see the note in ZephrCore/Package.swift
# for why the flag lives here rather than in the manifest.
ci-core:
    swift test --package-path ZephrCore -Xswiftc -warnings-as-errors

# What CI's app-build job runs.
ci-app:
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" -quiet

# Run everything CI runs, locally.
ci: lint ci-core ci-app

# Remove build products.
clean:
    rm -rf {{dist}} {{build_dir}} ZephrCore/.build
