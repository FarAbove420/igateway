#!/bin/zsh
#
# Builds what iGateway.exe links against, from source, as static libraries
# in deps/out: OpenSSL, FFmpeg's H.264 decoder, then FreeRDP. Needs only the
# Xcode Command Line Tools.
# CMake is downloaded for the build and is not part of the app.
#
# Every download is checked against the SHA-256 its project publishes.
#
# A different FreeRDP or FFmpeg source instead of the release (rarely needed):
#   FREERDP_SOURCE=~/src/FreeRDP ./deps/build-deps.zsh
#   FFMPEG_SOURCE=~/src/FFmpeg ./deps/build-deps.zsh
#
# --test-server also builds FreeRDP's sample server into deps/out/bin, for
# the integration test. It is never part of the app.
#
# Run again after changing a version: it rebuilds what changed. To start
# over, delete deps/build and deps/out.
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

CMAKE_VERSION="4.4.4"
CMAKE_SHA256="4b7b73704b1db9b374e5c9ab8e17ac6148b817b6396ee75cd94a852cbac9d305"
OPENSSL_VERSION="3.6.5"
OPENSSL_SHA256="a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98"
# ffmpeg.org publishes signatures, not checksums. This SHA-256 matches the one
# Homebrew publishes for the same file.
FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
FREERDP_VERSION="3.32.2"
FREERDP_SHA256="e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c"

# fetch <url> <sha256>: downloads once, then checks the file every run.
fetch() {
  local url="$1" sum="$2" file="$DOWNLOADS/${1:t}"
  mkdir -p "$DOWNLOADS"
  if [[ ! -f "$file" ]]; then
    print "Downloading ${file:t}..."
    curl -fL --progress-bar -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  if [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]]; then
    print -u2 "${file:t} does not match its published SHA-256. Deleted it; run again to retry."
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

# --- FFmpeg ------------------------------------------------------------------
# Only the H.264 decoder, which FreeRDP uses for the AVC420 and AVC444 codecs
# Windows prefers, and swscale, which FreeRDP's H.264 code includes. No GPL parts, so it stays LGPL. --disable-autodetect keeps it
# from picking up anything installed on the Mac.

if [[ -n "${FFMPEG_SOURCE:-}" ]]; then
  FFMPEG_SRC="${FFMPEG_SOURCE:A}"
  FFMPEG_ID="custom"
  rm -f "$OUT"/.ffmpeg-*(N)
else
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
  FFMPEG_SRC="$BUILD/ffmpeg-src"
  FFMPEG_ID="$FFMPEG_VERSION"
fi
FFMPEG_STAMP="$OUT/.ffmpeg-$FFMPEG_ID"
if [[ "$FFMPEG_ID" == custom || ! -f "$FFMPEG_STAMP" ]]; then
  print "Building FFmpeg ($FFMPEG_ID, H.264 decoder only)..."
  if [[ "$FFMPEG_ID" != custom ]]; then
    unpack "$DOWNLOADS/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION" "$FFMPEG_SRC"
  fi
  rm -rf "$BUILD/ffmpeg" "$BUILD/ffmpeg.log"
  mkdir -p "$BUILD/ffmpeg"
  cd "$BUILD/ffmpeg"
  step ffmpeg.log "$FFMPEG_SRC/configure" --prefix="$PREFIX" --libdir="$PREFIX/lib" \
    --enable-static --disable-shared --disable-autodetect \
    --disable-programs --disable-doc --disable-network \
    --disable-everything --enable-decoder=h264 --enable-parser=h264 \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swresample \
    --arch=arm64 --target-os=darwin --cc=clang \
    --extra-cflags="-mmacosx-version-min=$MACOS_MIN" --extra-ldflags="-mmacosx-version-min=$MACOS_MIN"
  step ffmpeg.log make -j"$JOBS"
  step ffmpeg.log make install DESTDIR="$STAGE-ffmpeg"
  collect "$STAGE-ffmpeg"
  # The LGPL text travels with the app; build.zsh copies it in.
  mkdir -p "$OUT/share"
  cp "$FFMPEG_SRC/COPYING.LGPLv2.1" "$OUT/share/FFmpeg-LGPL-2.1.txt"
  cd "$DEPS"
  rm -f "$OUT"/.ffmpeg-*(N)
  [[ "$FFMPEG_ID" == custom ]] || touch "$FFMPEG_STAMP"
fi

# --- FreeRDP -----------------------------------------------------------------
# Static libraries with the client channels built in. FFmpeg only for H.264
# video; audio stays with FreeRDP's own codecs. No X11, SDL, CUPS, PC/SC,
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
  -DWITH_FFMPEG=ON
  -DWITH_DSP_FFMPEG=OFF
  -DWITH_VIDEO_FFMPEG=ON
  -DWITH_FFMPEG_HWACCEL=OFF
  -DWITH_SWSCALE=ON
  -DWITH_SWSCALE_LOADING=OFF
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
fi

print "Done: $OUT"
