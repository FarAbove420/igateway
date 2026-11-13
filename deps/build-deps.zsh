#!/bin/zsh
#
# Builds what iGateway.exe links against, from source, as static libraries
# in deps/out: OpenSSL, FreeRDP, then SwiftTerm for SSH sessions. Needs only
# the Xcode Command Line Tools.
# CMake is downloaded for the build and is not part of the app.
#
# Every download is checked against a pinned SHA-256.
#
# A different FreeRDP source instead of the release (rarely needed):
#   FREERDP_SOURCE=~/src/FreeRDP ./deps/build-deps.zsh
#
# --test-server also builds FreeRDP's sample server into deps/out/bin, for
# the integration test. It is never part of the app.
#
# build.zsh runs this by itself when the libraries are missing or this file
# changed. Run again after changing a version: it rebuilds what changed. To
# start over, delete deps/build and deps/out.
#

set -eu

TEST_SERVER=0
for arg in "$@"; do
  case "$arg" in
    --test-server) TEST_SERVER=1 ;;
    *) print -u2 "Unknown option: $arg"; exit 1 ;;
  esac
done

DEPS="${0:A:h}"
DOWNLOADS="$DEPS/downloads"
TOOLS="$DEPS/tools"
BUILD="$DEPS/build"
OUT="$DEPS/out"
# The libraries remember where they were installed. Building for this neutral
# prefix and staging the files into deps/out keeps the builder's own folders
# out of the app. Nothing is ever installed in /opt/igateway.
PREFIX="/opt/igateway"
STAGE="$BUILD/stage"
JOBS="$(sysctl -n hw.ncpu)"
MACOS_MIN="13.0"

CMAKE_VERSION="4.5.0"
CMAKE_SHA256="a645d69fd21e521759cc0c64e7c60462d43faf0c7214ac05f75c80f7c5037dde"
OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
FREERDP_VERSION="3.33.1"
FREERDP_SHA256="4431bbf04d370545cfe2924b9d9f116b95c90c64ff156b2550bbaf82d34e7124"
# GitHub publishes no checksum for a tag's source archive. This is the SHA-256
# of the v1.20.0 archive as downloaded on 2026-11-04.
SWIFTTERM_VERSION="1.20.0"
SWIFTTERM_SHA256="36b39a2a4a63afc02099879e00a2b10f7d891c2b8b967db8af6ff45f81cf90f1"

# fetch <url> <sha256> [file name]: downloads once, then checks the file every run.
fetch() {
  local url="$1" sum="$2" file="$DOWNLOADS/${3:-${1:t}}"
  mkdir -p "$DOWNLOADS"
  if [[ ! -f "$file" ]]; then
    print "Downloading ${file:t}..."
    curl -fL --progress-bar -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  if [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]]; then
    print -u2 "${file:t} does not match its pinned SHA-256. Deleted it; run again to retry."
    rm -f "$file"
    exit 1
  fi
}

# step <log> <command...>: runs quietly into deps/build/<log>, shows its end on failure.
step() {
  local log="$BUILD/$1"
  shift
  mkdir -p "$BUILD"
  if ! "$@" >> "$log" 2>&1; then
    print -u2 "Failed. The end of $log:"
    tail -25 "$log" >&2
    exit 1
  fi
}

# collect <stage folder>: moves what an install put under $PREFIX into deps/out.
collect() {
  mkdir -p "$OUT"
  ditto "$1$PREFIX" "$OUT"
  rm -rf "$1"
}

# unpack <archive> <folder name inside> <destination>
unpack() {
  rm -rf "$3"
  mkdir -p "${3:h}"
  tar -xf "$1" -C "${3:h}"
  [[ "${3:h}/$2" == "$3" ]] || mv "${3:h}/$2" "$3"
}

# --- CMake -------------------------------------------------------------------

fetch "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz" \
      "$CMAKE_SHA256"
CMAKE="$TOOLS/cmake-$CMAKE_VERSION/CMake.app/Contents/bin/cmake"
if [[ ! -x "$CMAKE" ]]; then
  unpack "$DOWNLOADS/cmake-$CMAKE_VERSION-macos-universal.tar.gz" "cmake-$CMAKE_VERSION-macos-universal" \
         "$TOOLS/cmake-$CMAKE_VERSION"
fi

# --- OpenSSL -----------------------------------------------------------------
# FreeRDP needs it for TLS, NLA and certificates. Its CMakeLists: "Only OpenSSL
# is tested on each release". macOS has no OpenSSL to link against.
# /etc/ssl is where macOS keeps its CA bundle (cert.pem), so certificates
# signed by a public CA are trusted without asking.

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
      "$OPENSSL_SHA256"
OPENSSL_STAMP="$OUT/.openssl-$OPENSSL_VERSION"
if [[ ! -f "$OPENSSL_STAMP" ]]; then
  print "Building OpenSSL $OPENSSL_VERSION..."
  unpack "$DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION" "$BUILD/openssl"
  rm -f "$BUILD/openssl.log"
  cd "$BUILD/openssl"
  step openssl.log ./Configure darwin64-arm64-cc no-shared no-tests no-docs \
    --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl -mmacosx-version-min="$MACOS_MIN"
  step openssl.log make -j"$JOBS" build_libs
  step openssl.log make install_dev DESTDIR="$STAGE-openssl"
  collect "$STAGE-openssl"
  cd "$DEPS"
  rm -f "$OUT"/.openssl-*(N)
  touch "$OPENSSL_STAMP"
fi

# --- FreeRDP -----------------------------------------------------------------
# Static libraries with the client channels built in. H.264 video through
# Apple's VideoToolbox, which leaves hardware or software decoding to macOS;
# audio stays with FreeRDP's own codecs. No FFmpeg, X11, SDL, CUPS, PC/SC,
# Kerberos or JSON.
# NTLM needs MD4 and RC4, which OpenSSL 3 keeps in its "legacy" module, a
# separate file a static build does not have. FreeRDP's own copies stand in.

if [[ -n "${FREERDP_SOURCE:-}" ]]; then
  FREERDP_SRC="${FREERDP_SOURCE:A}"
  FREERDP_ID="custom"
else
  fetch "https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION/freerdp-$FREERDP_VERSION.tar.gz" \
        "$FREERDP_SHA256"
  FREERDP_SRC="$BUILD/freerdp-src"
  FREERDP_ID="$FREERDP_VERSION"
  if [[ ! -f "$FREERDP_SRC/.version-$FREERDP_VERSION" ]]; then
    unpack "$DOWNLOADS/freerdp-$FREERDP_VERSION.tar.gz" "freerdp-$FREERDP_VERSION" "$FREERDP_SRC"
    touch "$FREERDP_SRC/.version-$FREERDP_VERSION"
  fi
fi

# CMake's cache remembers the source folder; a different one needs a fresh build folder.
if [[ -f "$BUILD/freerdp/CMakeCache.txt" ]] && ! grep -q -F "CMAKE_HOME_DIRECTORY:INTERNAL=$FREERDP_SRC" "$BUILD/freerdp/CMakeCache.txt"; then
  rm -rf "$BUILD/freerdp"
fi
print "Building FreeRDP ($FREERDP_ID)..."
rm -f "$BUILD/freerdp.log"
FREERDP_OPTIONS=(
  # FreeRDP takes its version from a git tag when it finds one. Its source
  # sits inside this repository, so on a release tag it took ours (v0.6.0 as
  # FreeRDP 0, headers in include/freerdp0). Off: the release's own version.
  -DUSE_VERSION_FROM_GIT_TAG=OFF
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$OUT"
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
  -DOPENSSL_ROOT_DIR="$OUT"
  -DOPENSSL_USE_STATIC_LIBS=ON
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTING=OFF
  -DWITH_CLIENT_COMMON=ON
  -DWITH_CLIENT=OFF
  -DWITH_CLIENT_SDL=OFF
  -DWITH_CLIENT_MAC=OFF
  -DWITH_SERVER=OFF
  -DWITH_SAMPLE=OFF
  -DWITH_PROXY=OFF
  -DWITH_SHADOW=OFF
  -DWITH_CHANNELS=ON
  -DWITH_CLIENT_CHANNELS=ON
  -DWITH_MACAUDIO=ON
  -DWITH_APPLE_VIDEOTOOLBOX=ON
  -DWITH_FFMPEG=OFF
  -DWITH_DSP_FFMPEG=OFF
  -DWITH_VIDEO_FFMPEG=OFF
  -DWITH_SWSCALE=OFF
  -DWITH_CAIRO=OFF
  -DWITH_OPENH264=OFF
  -DWITH_X11=OFF
  -DWITH_WAYLAND=OFF
  -DWITH_CUPS=OFF
  -DWITH_PCSC=OFF
  -DWITH_PKCS11=OFF
  -DWITH_FUSE=OFF
  -DWITH_KRB5=OFF
  -DWITH_JSON_DISABLED=ON
  -DWITH_AAD=OFF
  -DWITH_INTERNAL_MD4=ON
  -DWITH_INTERNAL_RC4=ON
  -DWITH_WINPR_TOOLS=OFF
  -DWITH_MANPAGES=OFF
  -DWITH_OPUS=OFF
  -DWITH_LAME=OFF
  -DWITH_FAAD2=OFF
  -DWITH_FAAC=OFF
  -DWITH_SOXR=OFF
  -DWITH_GSM=OFF
  -DCHANNEL_URBDRC=OFF
)
# pkg-config, when installed (Homebrew's often is), may only see our own
# libraries: elsewhere it would point CMake at Homebrew's.
export PKG_CONFIG_LIBDIR="$OUT/lib/pkgconfig" PKG_CONFIG_PATH=""
step freerdp.log "$CMAKE" -S "$FREERDP_SRC" -B "$BUILD/freerdp" -G "Unix Makefiles" -Wno-dev $FREERDP_OPTIONS
step freerdp.log "$CMAKE" --build "$BUILD/freerdp" -j "$JOBS"
DESTDIR="$STAGE-freerdp" step freerdp.log "$CMAKE" --install "$BUILD/freerdp"
collect "$STAGE-freerdp"

# No library or header from a package manager may have slipped in. Tools such
# as git or pkg-config found there are fine: they don't end up in the app.
leaks="$(grep -E "^[A-Za-z0-9_]*(LIBRARY|LIBRARIES|INCLUDE_DIR|INCLUDE_DIRS)[A-Za-z0-9_]*:(FILEPATH|PATH|STRING)=(/opt/homebrew|/usr/local|/opt/local)" "$BUILD/freerdp/CMakeCache.txt" || true)"
if [[ -n "$leaks" ]]; then
  print -u2 "FreeRDP picked up libraries from outside deps/out:"
  print -u2 "$leaks"
  exit 1
fi

# --- SwiftTerm -------------------------------------------------------------------
# The terminal for SSH sessions. Built with swiftc directly: no Swift package
# manager, no Xcode. Its iOS files are left out, and the file its package
# plugin would generate is written here. A Swift module only loads in the
# compiler that built it, so the stamp includes the compiler's version.

fetch "https://github.com/migueldeicaza/SwiftTerm/archive/refs/tags/v$SWIFTTERM_VERSION.tar.gz" \
      "$SWIFTTERM_SHA256" "SwiftTerm-$SWIFTTERM_VERSION.tar.gz"
SWIFTTERM_STAMP="$OUT/.swiftterm-$SWIFTTERM_VERSION-$(swiftc --version 2>&1 | shasum | cut -c1-12)"
if [[ ! -f "$SWIFTTERM_STAMP" ]]; then
  print "Building SwiftTerm ($SWIFTTERM_VERSION)..."
  SWIFTTERM_SRC="$BUILD/swiftterm-src"
  unpack "$DOWNLOADS/SwiftTerm-$SWIFTTERM_VERSION.tar.gz" "SwiftTerm-$SWIFTTERM_VERSION" "$SWIFTTERM_SRC"
  rm -rf "$BUILD/swiftterm" "$BUILD/swiftterm.log"
  mkdir -p "$BUILD/swiftterm" "$OUT/lib" "$OUT/swift" "$OUT/share"
  cat > "$BUILD/swiftterm/SwiftTermBuildInfo.swift" <<EOF
// What SwiftTerm's build plugin would generate.
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v$SWIFTTERM_VERSION"
    public static let commit: String? = nil
    public static let hasUncommittedChanges: Bool? = false
    public static let version: String = "v$SWIFTTERM_VERSION"
}
EOF
  swiftterm_files=("$SWIFTTERM_SRC"/Sources/SwiftTerm/**/*.swift(N) "$BUILD/swiftterm/SwiftTermBuildInfo.swift")
  swiftterm_files=(${swiftterm_files:#*/iOS/*})
  # The prefix map keeps the build folder's path out of the app.
  step swiftterm.log swiftc -O -parse-as-library -swift-version 5 \
    -target "arm64-apple-macos$MACOS_MIN" -module-name SwiftTerm \
    -file-prefix-map "$SWIFTTERM_SRC=/opt/igateway/src/SwiftTerm" \
    -emit-module -emit-module-path "$OUT/swift/SwiftTerm.swiftmodule" \
    -emit-library -static -o "$OUT/lib/libSwiftTerm.a" $swiftterm_files
  cp "$SWIFTTERM_SRC/LICENSE" "$OUT/share/SwiftTerm-LICENSE.txt"
  rm -f "$OUT"/.swiftterm-*(N)
  touch "$SWIFTTERM_STAMP"
fi

# --- The test server ----------------------------------------------------------
# FreeRDP's sample server, built from the same source with the same options in
# its own build folder, so the app's libraries above stay as they are.

if (( TEST_SERVER )); then
  print "Building FreeRDP's sample server (tests only)..."
  rm -f "$BUILD/freerdp-server.log"
  step freerdp-server.log "$CMAKE" -S "$FREERDP_SRC" -B "$BUILD/freerdp-server" -G "Unix Makefiles" -Wno-dev \
    $FREERDP_OPTIONS -DWITH_SERVER=ON -DWITH_SAMPLE=ON -DWITH_SERVER_CHANNELS=ON
  step freerdp-server.log "$CMAKE" --build "$BUILD/freerdp-server" --target sfreerdp-server -j "$JOBS"
  mkdir -p "$OUT/bin"
  cp "$BUILD/freerdp-server/server/Sample/sfreerdp-server" "$OUT/bin/"
  # It shows this icon after login and drops the session when it can't find it
  # in the folder it runs from. BMP, because WinPR reads that without extra libraries.
  cp "$FREERDP_SRC/server/Sample/test_icon.bmp" "$OUT/bin/"
fi

# What build.zsh looks for: built by this very file with this compiler.
# $DEPS, not $0: this folder has been left by now, and $0 may be relative.
DEPS_ID="$(cat "$DEPS/build-deps.zsh" <(swiftc --version 2>&1) | shasum | cut -c1-16)"
rm -f "$OUT"/.deps-*(N)
touch "$OUT/.deps-$DEPS_ID"
print "Done: $OUT"
