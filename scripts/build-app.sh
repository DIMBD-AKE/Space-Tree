#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_options=(-c release)
sign_options=(--timestamp=none)
case "${1:-}" in
    "") ;;
    --release)
        build_options+=(--arch arm64 --arch x86_64)
        sign_options=(--options runtime --timestamp)
        ;;
    *) printf '%s\n' 'Usage: build-app.sh [--release]' >&2; exit 2 ;;
esac
swift build "${build_options[@]}"
bin_path=$(swift build "${build_options[@]}" --show-bin-path)
app="$(pwd)/dist/Space Tree.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/SpaceTree" "$app/Contents/MacOS/SpaceTree.new"
mv -f "$app/Contents/MacOS/SpaceTree.new" "$app/Contents/MacOS/SpaceTree"
swift scripts/make-icon.swift .build/SpaceTree.iconset
iconutil -c icns .build/SpaceTree.iconset -o "$app/Contents/Resources/SpaceTree.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>SpaceTree</string>
    <key>CFBundleIdentifier</key><string>local.spacetree</string>
    <key>CFBundleName</key><string>Space Tree</string>
    <key>CFBundleDisplayName</key><string>Space Tree</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>SpaceTree</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
signing_identity="${SPACETREE_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ { print $2; exit }')
fi
if [ "${1:-}" = --release ]; then
    if ! security find-identity -v -p codesigning | awk -v identity="$signing_identity" '
        /Developer ID Application:/ && ($2 == identity || index($0, "\"" identity "\"")) { found = 1 }
        END { exit !found }'; then
        printf '%s\n' 'Distribution requires a valid Developer ID Application identity.' >&2
        exit 1
    fi
fi
if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '/Apple Development:/ { print $2; exit }')
fi
if [ -z "$signing_identity" ]; then
    signing_identity=-
    printf '%s\n' 'No signing certificate: ad-hoc builds may require granting file permissions again after updates.' >&2
fi
codesign --force --sign "$signing_identity" "${sign_options[@]}" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
