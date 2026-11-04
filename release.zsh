#!/bin/zsh
#
# Builds the app and packs it for a release:
#   dist/iGateway.exe-<version>-arm64.zip and its .sha256
# Refuses when the app still contains paths from this Mac.
#
# Signed and notarized, for a download that opens like any Mac app, with a
# Developer ID (needs an Apple Developer account):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=igateway ./release.zsh
# NOTARY_PROFILE is a name saved once with:
#   xcrun notarytool store-credentials igateway --apple-id <id> --team-id <TEAMID> --password <app-specific password>
# Without these it packs the ad-hoc signed build.
#

set -eu

ROOT="${0:A:h}"
"$ROOT/build.zsh"

APP="$ROOT/build.noindex/iGateway.exe.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  print "Signing with $SIGN_IDENTITY..."
  # Notarization needs the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

# Raw bytes, not strings(1): that skips parts of the file, like the debug map.
if LC_ALL=C grep -q -a -F "$HOME" "$APP/Contents/MacOS/igateway"; then
  print -u2 "The app contains paths from this Mac ($HOME). Not packing it."
  exit 1
fi
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
  print -u2 "The app's signature does not verify. Not packing it."
  exit 1
fi
for file in LICENSE THIRD_PARTY_NOTICES.md SwiftTerm-LICENSE.txt; do
  if [[ ! -f "$APP/Contents/Resources/$file" ]]; then
    print -u2 "$file is missing from the app. Not packing it."
    exit 1
  fi
done

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/iGateway.exe-$VERSION-arm64.zip"
pack() {
  rm -f "$ZIP" "$ZIP.sha256"
  # Only the files: no extended attributes or ACLs from this Mac.
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$ZIP"
}
pack

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || { print -u2 "NOTARY_PROFILE needs SIGN_IDENTITY too."; exit 1 }
  print "Notarizing (this can take a few minutes)..."
  result="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  print "$result"
  if ! print "$result" | grep -q "status: Accepted"; then
    print -u2 "Notarization was not accepted. Not packing it."
    rm -f "$ZIP"
    exit 1
  fi
  # The ticket goes into the app, so it opens without a network check too.
  xcrun stapler staple "$APP"
  pack
fi

(cd "$ROOT/dist" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
print "Packed $ZIP"
cat "$ZIP.sha256"
