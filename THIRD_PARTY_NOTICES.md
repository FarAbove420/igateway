# Third-party software

iGateway.exe is licensed under the Apache License 2.0 (see `LICENSE`). The
app compiles in the following software, built from source by
`deps/build-deps.zsh`.

## FreeRDP

- https://github.com/FreeRDP/FreeRDP, version 3.32.2 unless built from another source
- Apache License 2.0, the same text as `LICENSE`
- Built with FreeRDP's own MD4 and RC4 (`WITH_INTERNAL_MD4`,
  `WITH_INTERNAL_RC4`); the MD4 code in `winpr/libwinpr/crypto` is in the
  public domain. See the FreeRDP source for details.

## FFmpeg

- https://ffmpeg.org, version 9.0.2: libavcodec (H.264 decoder only),
  libavutil and libswscale
- GNU Lesser General Public License 2.1 or later. Built without the GPL and
  non-free parts (`CONFIG_GPL 0`, `CONFIG_NONFREE 0`). `build.zsh` puts the
  licence text in the app as `FFmpeg-LGPL-2.1.txt`.
- Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
- Linked statically. Everything needed to rebuild and relink the app against
  a modified FFmpeg is in this repository (https://github.com/FarAbove420/igateway):
  `FFMPEG_SOURCE=/path/to/FFmpeg ./deps/build-deps.zsh`, then `./build.zsh`.

## OpenSSL

- https://github.com/openssl/openssl, version 3.6.5
- Apache License 2.0, the same text as `LICENSE`
- Copyright the OpenSSL Project Authors

## SwiftTerm

- https://github.com/migueldeicaza/SwiftTerm, version 1.20.0, the terminal
  for SSH sessions
- MIT License, copyright Miguel de Icaza and the xterm.js authors.
  `build.zsh` puts the licence text in the app as `SwiftTerm-LICENSE.txt`.

Nothing else is linked besides frameworks and libraries that ship with macOS.
CMake is downloaded to build FreeRDP and is not part of the app.
