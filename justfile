# Zephr build & release pipeline. `just` lists recipes.
#
# Local:    just test build run
# Ship:     just archive export dmg notarize   (needs Developer ID; see
#           `just notary-setup` once for credentials)
# Quick:    just app dmg                       (dev-signed DMG for yourself)

set shell := ["bash", "-cu"]

project := "Zephr.xcodeproj"
scheme := "Zephr"
dist := "dist"
build_dir := "build"
version := `awk -F' = |;' '/MARKETING_VERSION/{print $2; exit}' Zephr.xcodeproj/project.pbxproj`
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
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug build | tail -2

# Build Debug and launch it.
run: build
    open "$(xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3; exit}')/{{scheme}}.app"

# Release build → dist/Zephr.app (signed with your development identity).
app:
    rm -rf {{dist}}/{{scheme}}.app
    mkdir -p {{dist}}
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        -derivedDataPath {{build_dir}} build | tail -2
    cp -R {{build_dir}}/Build/Products/Release/{{scheme}}.app {{dist}}/
    @echo "→ {{dist}}/{{scheme}}.app"

# Archive for distribution.
archive:
    mkdir -p {{dist}}
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        archive -archivePath {{archive}} | tail -2
    @echo "→ {{archive}}"

# Export a Developer ID–signed app from the archive → dist/Zephr.app.
export:
    xcodebuild -exportArchive -archivePath {{archive}} \
        -exportOptionsPlist tools/ExportOptions.plist \
        -exportPath {{dist}} | tail -2
    @echo "→ {{dist}}/{{scheme}}.app (Developer ID)"

# Package dist/Zephr.app into a drag-to-Applications DMG.
dmg:
    test -d {{dist}}/{{scheme}}.app || { echo "no {{dist}}/{{scheme}}.app — run 'just app' (dev) or 'just archive export' (Developer ID) first"; exit 1; }
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

# Full release pipeline: archive → export → dmg → notarize.
release: archive export dmg notarize

# Copy dist/Zephr.app into /Applications (quits a running instance first).
install:
    test -d {{dist}}/{{scheme}}.app || { echo "no {{dist}}/{{scheme}}.app — run 'just app' first"; exit 1; }
    -pkill -TERM -x {{scheme}} 2>/dev/null; sleep 1
    rm -rf /Applications/{{scheme}}.app
    cp -R {{dist}}/{{scheme}}.app /Applications/
    open /Applications/{{scheme}}.app

# Regenerate the app icon assets from tools/make-icon.swift.
icon:
    swift tools/make-icon.swift

# Install the zephrctl CLI to /usr/local/bin.
cli:
    sudo install -m 0755 tools/zephrctl /usr/local/bin/zephrctl
    @echo "→ /usr/local/bin/zephrctl"

# What CI runs.
ci: test
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" | tail -2

# Remove build products.
clean:
    rm -rf {{dist}} {{build_dir}} ZephrCore/.build
