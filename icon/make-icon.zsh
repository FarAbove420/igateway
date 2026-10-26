#!/bin/zsh
# Rebuilds icon/AppIcon.icns and icon/SessionIcon.icns from make-icon.swift.
# Only needed after changing the drawing; build.zsh uses the .icns files here.
set -eu
DIR="${0:A:h}"
TMP="$(mktemp -d)"
swiftc -O "$DIR/make-icon.swift" -o "$TMP/make-icon"
"$TMP/make-icon" "$DIR/icon-1024.png" "$DIR/session-1024.png"
for name in AppIcon:icon SessionIcon:session; do
  icns="${name%%:*}" png="$DIR/${name##*:}-1024.png"
  SET="$TMP/$icns.iconset"
  mkdir "$SET"
  for px in 16 32 128 256 512; do
    sips -z $px $px "$png" --out "$SET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$png" --out "$SET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$DIR/$icns.icns"
  print "Wrote $DIR/$icns.icns"
done
rm -rf "$TMP"
