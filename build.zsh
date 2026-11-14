#!/bin/zsh
#
# Builds "iGateway.exe.app".
#
# Links FreeRDP, OpenSSL and SwiftTerm statically from deps/out, so the app
# needs nothing installed on the Mac it runs on. It builds those first, with
# deps/build-deps.zsh, when they are missing or out of date.
#
# Usage:
#   ./build.zsh              build into ./build.noindex
#   ./build.zsh --install    build, then install into ~/Applications
#
# BUNDLE_ID overrides the bundle identifier, for your own builds.
#

set -eu

SRC_DIR="${0:A:h}"
DEPS="$SRC_DIR/deps/out"
# ".noindex" keeps Spotlight and Launchpad from listing the build copy
# next to the installed app.
BUILD_DIR="$SRC_DIR/build.noindex"
APP_NAME="iGateway.exe"
APP="$BUILD_DIR/${APP_NAME}.app"
EXEC_NAME="igateway"
BUNDLE_ID="${BUNDLE_ID:-io.github.farabove420.igateway}"
VERSION="0.8.0"

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) print -u2 "Unknown option: $arg"; exit 1 ;;
  esac
done

# The libraries, built first when they aren't there yet, or when
# deps/build-deps.zsh or the compiler changed since (it leaves a stamp).
DEPS_ID="$(cat "$SRC_DIR/deps/build-deps.zsh" <(swiftc --version 2>&1) | shasum | cut -c1-16)"
if [[ ! -f "$DEPS/.deps-$DEPS_ID" ]]; then
  print "Building the libraries first. The first time takes a few minutes."
  "$SRC_DIR/deps/build-deps.zsh" || exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

print "Compiling the FreeRDP bridge..."
mkdir -p "$BUILD_DIR"
cc -c "$SRC_DIR/bridge/rdpbridge.c" \
   -I "$SRC_DIR/bridge" \
   -I "$DEPS/include/freerdp3" \
   -I "$DEPS/include/winpr3" \
   -arch arm64 -mmacosx-version-min=13.0 \
   -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -O2 \
   -o "$BUILD_DIR/rdpbridge.o"

print "Compiling the app..."
# -parse-as-library because @main is not in a file called main.swift.
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -import-objc-header "$SRC_DIR/bridge/rdpbridge.h" \
  -I "$SRC_DIR/bridge" -I "$DEPS/swift" \
  "$SRC_DIR"/swift/*.swift \
  "$BUILD_DIR/rdpbridge.o" \
  "$DEPS/lib/libfreerdp-client3.a" "$DEPS/lib/libfreerdp3.a" "$DEPS/lib/libwinpr3.a" \
  "$DEPS"/lib/freerdp3/*.a \
  "$DEPS/lib/libssl.a" "$DEPS/lib/libcrypto.a" "$DEPS/lib/libSwiftTerm.a" \
  "$(xcrun --show-sdk-path)/usr/lib/libz.tbd" \
  -framework Carbon -framework IOSurface -framework AVFoundation -framework AudioToolbox -framework CoreAudio \
  -framework Security -framework SystemConfiguration -framework IOKit -framework CoreFoundation \
  -framework Metal -framework MetalKit -framework CoreText \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -o "$APP/Contents/MacOS/$EXEC_NAME"

chmod 755 "$APP/Contents/MacOS/$EXEC_NAME"

# The debug map lists the object files the libraries were built from, with
# the builder's folders in them. Function names stay, for crash reports.
strip -S "$APP/Contents/MacOS/$EXEC_NAME"

# Only macOS itself may be linked dynamically.
if otool -L "$APP/Contents/MacOS/$EXEC_NAME" | tail -n +2 | grep -v -E "^\s+(/usr/lib/|/System/)" | grep -q .; then
  print -u2 "The app links a library outside macOS:"
  otool -L "$APP/Contents/MacOS/$EXEC_NAME" >&2
  exit 1
fi

# The icons come from icon/make-icon.zsh. SessionIcon is for the per-server
# Dock tiles.
cp "$SRC_DIR/icon/SessionIcon.icns" "$APP/Contents/Resources/" 2>/dev/null || true
ICON="$SRC_DIR/icon/AppIcon.icns"
[[ -f "$ICON" ]] || ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/public.generic-pc.icns"
ICON_KEY=""
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>${EXEC_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
${ICON_KEY}</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The licences of what is compiled in travel with the app.
cp "$SRC_DIR/LICENSE" "$SRC_DIR/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/" 2>/dev/null || true
cp "$DEPS/share/SwiftTerm-LICENSE.txt" "$APP/Contents/Resources/" 2>/dev/null || true

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  print "note: ad-hoc code signing was skipped."

print "Built $APP"

if (( INSTALL )); then
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/${APP_NAME}.app"
  cp -R "$APP" "$HOME/Applications/"
  print "Installed to $HOME/Applications/${APP_NAME}.app"
fi
