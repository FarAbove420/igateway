#!/bin/zsh
#
# Builds and runs the tests. Nothing appears on screen and the Mac clipboard
# is not touched. CFFIXED_USER_HOME points the app's config, logs and caches
# at tests/build/home, so the real ones are never read or written.
#
# The integration test needs FreeRDP's sample server. ./deps/build-deps.zsh
# --test-server builds it into deps/out/bin; SFREERDP_SERVER points at another.
#

set -u

TESTS="${0:A:h}"
ROOT="${TESTS:h}"
DEPS="$ROOT/deps/out"
OUT="$TESTS/build"
[[ -f "$DEPS/lib/libfreerdp3.a" ]] || { print -u2 "Build the dependencies first: ./deps/build-deps.zsh"; exit 1 }
mkdir -p "$OUT/home" "$OUT/share"
export CFFIXED_USER_HOME="$OUT/home"
# FreeRDP keeps trusted certificates under $XDG_CONFIG_HOME/freerdp.
export XDG_CONFIG_HOME="$OUT/home/.config"

# The app's sources minus App.swift's @main, so each test has its own entry point.
sed '/^@main$/d' "$ROOT/swift/App.swift" > "$OUT/App.swift"
SOURCES=("$OUT/App.swift" ${(f)"$(ls "$ROOT"/swift/*.swift | grep -v '/App.swift$')"})
INCLUDES=(-I "$ROOT/bridge" -I "$DEPS/include/freerdp3" -I "$DEPS/include/winpr3")
CFLAGS=(-arch arm64 -mmacosx-version-min=13.0 -Wno-deprecated-declarations -O1)
LINK=(
  "$DEPS/lib/libfreerdp-client3.a" "$DEPS/lib/libfreerdp3.a" "$DEPS/lib/libwinpr3.a" "$DEPS"/lib/freerdp3/*.a
  "$DEPS/lib/libavcodec.a" "$DEPS/lib/libswscale.a" "$DEPS/lib/libavutil.a"
  "$DEPS/lib/libssl.a" "$DEPS/lib/libcrypto.a" "$(xcrun --show-sdk-path)/usr/lib/libz.tbd"
  -framework Carbon -framework IOSurface -framework AVFoundation -framework AudioToolbox -framework CoreAudio
  -framework Security -framework SystemConfiguration -framework IOKit -framework CoreFoundation
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo
)

print "Building..."
cc -c "$ROOT/bridge/rdpbridge.c" $INCLUDES $CFLAGS -o "$OUT/rdpbridge.o" || exit 1
cc -c "$TESTS/unit/shim.c" $INCLUDES $CFLAGS -o "$OUT/shim.o" || exit 1

# build <test> <bridging header> [extra objects]
build() {
  local name="$1" header="$2"
  shift 2
  if ! swiftc -target arm64-apple-macos13.0 -I "$ROOT/bridge" -import-objc-header "$header" \
         "$TESTS/$name/main.swift" $SOURCES "$OUT/rdpbridge.o" "$@" $LINK \
         -o "$OUT/$name" > "$OUT/$name.log" 2>&1; then
    grep "error:" "$OUT/$name.log"
    return 1
  fi
}
build unit "$TESTS/unit/shim.h" "$OUT/shim.o" || exit 1
build input "$ROOT/bridge/rdpbridge.h" || exit 1
build session "$ROOT/bridge/rdpbridge.h" || exit 1
build integration "$ROOT/bridge/rdpbridge.h" || exit 1

failed=0
# run <test> [arguments]: prints failures and the summary line.
run() {
  local name="$1"
  shift
  print "== $name"
  "$OUT/$name" "$@" > "$OUT/$name.out" 2>&1 || failed=1
  grep -E "FAIL|passed" "$OUT/$name.out"
}
run unit
run input
run session "$OUT"

SFREERDP_SERVER="${SFREERDP_SERVER:-$DEPS/bin/sfreerdp-server}"
if [[ -x "$SFREERDP_SERVER" ]]; then
  if [[ ! -f "$OUT/server/cert.pem" ]]; then
    mkdir -p "$OUT/server"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=localhost" \
      -keyout "$OUT/server/key.pem" -out "$OUT/server/cert.pem" 2>/dev/null
  fi
  "$SFREERDP_SERVER" --port=13389 --cert="$OUT/server/cert.pem" --key="$OUT/server/key.pem" \
    > "$OUT/server.log" 2>&1 &
  server=$!
  trap 'kill $server 2>/dev/null' EXIT INT TERM
  for i in {1..50}; do nc -z 127.0.0.1 13389 2>/dev/null && break; sleep 0.2; done
  run integration "$OUT/share"
  kill $server 2>/dev/null
  wait $server 2>/dev/null
else
  print "== integration: skipped, build the test server: ./deps/build-deps.zsh --test-server"
fi

exit $failed
