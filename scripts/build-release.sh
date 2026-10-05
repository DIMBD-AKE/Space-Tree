#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${SPACETREE_NOTARY_PROFILE:-}" ]; then
    auth=(--keychain-profile "$SPACETREE_NOTARY_PROFILE")
else
    auth=(--key "${SPACETREE_NOTARY_KEY:?Set SPACETREE_NOTARY_PROFILE or SPACETREE_NOTARY_KEY}"
          --key-id "${SPACETREE_NOTARY_KEY_ID:?Set SPACETREE_NOTARY_KEY_ID}")
    if [ -n "${SPACETREE_NOTARY_ISSUER:-}" ]; then
        auth+=(--issuer "$SPACETREE_NOTARY_ISSUER")
    fi
fi

bash scripts/build-app.sh --release
app="$(pwd)/dist/Space Tree.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="$(pwd)/dist/Space-Tree-$version-universal.dmg"
identity=$(codesign -d --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p')
test -n "$identity"

notarize() {
    local archive="$1" report="$2"
    xcrun notarytool submit "$archive" "${auth[@]}" --wait --output-format json > "$report"
    python3 - "$report" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
print('Notarization:', report.get('status'), report.get('id'))
if report.get('status') != 'Accepted':
    sys.exit('Notarization failed. Use notarytool log with the submission ID for details.')
PY
}

ditto -c -k --keepParent "$app" dist/Space-Tree-notarization.zip
notarize dist/Space-Tree-notarization.zip dist/app-notarization.json
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

stage=$(mktemp -d "$(pwd)/dist/dmg-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Space Tree.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname 'Space Tree' -srcfolder "$stage" -format UDZO -ov "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
notarize "$dmg" dist/dmg-notarization.json
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd dist && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt)
printf '%s\n' "$dmg"
