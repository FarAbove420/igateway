# How it works, and why

The details behind the README. The app is AppKit plus a small C bridge
(`bridge/rdpbridge.c`) over FreeRDP's client library.

## Building

`deps/build-deps.zsh` builds three libraries as static libraries in
`deps/out`, all for Apple Silicon and macOS 13:

- **OpenSSL 3.6.5**, which FreeRDP uses for TLS, NLA and certificates.
  FreeRDP's own build files say only OpenSSL is tested on each release, and
  macOS has no OpenSSL to link against.
- **FFmpeg 9.0.2**, only the H.264 decoder and swscale, for the H.264
  (AVC420 and AVC444) video Windows sends. Built without FFmpeg's GPL and
  non-free parts, so it stays LGPL.
- **FreeRDP 3.32.2**, with the client channels built in.

It also downloads CMake to build FreeRDP; CMake is not part of the app. Each
download is checked against its SHA-256: the one the project publishes, or for
FFmpeg, which publishes signatures instead, the one Homebrew publishes for the
same file.

The libraries are built for the prefix `/opt/igateway` and then staged into
`deps/out`. Libraries remember their install folder, and this keeps the
builder's own folders out of the app. Nothing is ever installed in
`/opt/igateway`.

`build.zsh` compiles the bridge and the Swift sources and links everything
into one executable that only needs macOS itself. `BUNDLE_ID=...` gives your
own builds their own bundle identifier.

The icons, an apple for the app and a PC for each session, are drawn by
`icon/make-icon.swift`; `icon/make-icon.zsh` rebuilds the `.icns` files.

## Where things are kept

- `~/Library/Application Support/iGateway/config.json`: servers, gateways,
  account names, settings. No passwords.
- `~/Library/Application Support/iGateway/history.json`: the last 30
  connections.
- `~/Library/Application Support/iGateway/Sessions.noindex`: the per-server
  session apps.
- Login Keychain, service `iGateway`: passwords you chose to save.
- `~/.config/freerdp/server`: certificates you trusted (FreeRDP's store).
- `~/Library/Logs/iGateway`: `app.log` (every connect with its FreeRDP
  options and account names, state changes, error codes, certificate
  decisions; never passwords or clipboard contents) and `freerdp.log`.
- `~/Library/Caches/iGateway/Clipboard`: files pasted from Windows, cleared on
  quit.

File, Export Hosts writes the gateways and servers, with their friendly names,
labels and label colours, to a JSON file. Import Hosts adds what a file has and
the list lacks.

## One app per session

macOS gives each running app one Dock tile, so each session runs as its own
process from a small bundle per server in `Sessions.noindex/<id>/<name>.app`
(`.noindex` keeps them out of Spotlight). The bundle is an `Info.plist` with
the server's name, its own bundle id and the server's id, plus a hard link to
the app's executable, so nothing is copied. It is rebuilt on every connect and
removed when its server is.

A hard link and not a symlink: a symlinked executable started by LaunchServices
resolves back to the main bundle and shows the main app's name. A tile kept in
the Dock starts through LaunchServices.

Passwords reach the session process over a pipe, never on the command line.
Started from a Dock tile there is no pipe; it then uses saved passwords, or
opens the server list when none are saved, rather than trying a login without
one.

Processes share safely: settings are re-read before every change, the
clipboard download folder is per process, and the log is appended with
`O_APPEND`. If a session app cannot be built, the session opens in a window of
the main app instead.

The Dock icon is drawn at runtime: the PC from the main app's
`SessionIcon.icns`, read from the file directly because macOS caches bundle
icons, with the label on its screen. Label colours too dark to read on the
black screen are lightened in the same hue.

## Recent connections

Each session process writes its attempt to `history.json`: started,
connected, ended, and why it failed. Writes take a file lock, so two sessions
changing state at once keep each other's entries. The server list reads the
file every second and redraws only when something changed. An entry counts as
open only while that server's session app is running, so a crashed session
shows as ended. Windows' "ended on purpose" reasons (signed out, disconnected
from the Start menu, taken over by another connection, idle timeout) count as
a normal close.

## Certificates

FreeRDP checks a certificate with OpenSSL against `/etc/ssl/cert.pem` and
against the certificates it stored for each server. That CA file lags behind
the Mac's trust store and lacks CAs an administrator or the user added, so
whatever FreeRDP can't verify is then checked by macOS itself (Security
framework, host name included). Only what macOS doesn't trust either is shown,
with subject, issuer and SHA-256 fingerprint: Trust (stored), Trust Once or
Cancel. A certificate that differs from the stored one is shown as a warning,
with Cancel as the default button.

NTLM logins need MD4 and RC4, which OpenSSL 3 only offers in a separately
loaded "legacy" module that a static build doesn't have. FreeRDP is built with
its own copies (`WITH_INTERNAL_MD4`, `WITH_INTERNAL_RC4`).

## Rendering

FreeRDP draws into its framebuffer on its own thread. Only the changed area is
copied, into IOSurfaces that Core Animation shows without another copy. A
surface is never written while it is on screen; each one tracks the area it is
missing and catches up on its next turn. Surfaces are tagged sRGB, because
untagged pixels look oversaturated on a wide-gamut display.

The GFX pipeline (how modern Windows servers send the screen) is set up by
FreeRDP's own channel handler. That handler casts the context to
`rdpClientContext`, so the bridge's context starts with one.
`update->DesktopResize` is always set: FreeRDP's GFX reset asserts on it.

## Resizing

Done by the server, not by stretching. A window size change becomes a Display
Control monitor layout, sent from the session thread at most every 500 ms (the
SDL client's interval) and only after the server has confirmed support. Per
MS-RDPEDISP 2.2.2.2.1 the width is rounded down to even and both sides are kept
within 200 to 8192.

Some servers time out during activation when dynamic resolution is on. Then
the app reconnects once without it and remembers that for the server.

## Clipboard (MS-RDPECLIP)

- **Text** is fetched the moment something is copied in Windows, so it still
  pastes after the session closes. CRLF and UTF-16 conversion both ways.
- **Images** and **files** from Windows are promised to the Mac pasteboard and
  only transferred when something pastes them.
- **Mac to Windows**: text as `CF_UNICODETEXT`, images as `CF_DIB` (flattened
  onto white, because many Windows apps ignore alpha) plus `PNG`, files and
  folders as `FileGroupDescriptorW` with contents served on request. Files of
  2 GB and up are only offered when the server supports huge files.
- A clipboard written by one session is never announced back to that same
  session, so copy and paste inside a Windows app keeps that app's own formats.
- Before Cmd-V is sent, the Mac clipboard is checked; if it just changed, the
  key waits 150 ms so the announcement reaches Windows first.

The 592-byte file descriptor layout is tested against FreeRDP's own
`cliprdr_parse_file_list` and `cliprdr_serialize_file_list`.

## Keyboard

In the default "Type what the Mac types" mode:

- Text goes through macOS text input (`interpretKeyEvents`, so dead keys
  compose) and is sent as Unicode. Windows gets the exact character whatever
  layout it thinks the keyboard has.
- Shortcuts, Ctrl combinations and non-text keys go as scancodes, from WinPR's
  Apple key table. The layout picker, which starts out matching the Mac's input
  source, makes Windows read those positions correctly.
- Option is only sent as Alt together with a non-text key, so typing an Option
  character never opens a Windows Alt menu.
- macOS does not deliver key-up events while Cmd is held, so Cmd combinations
  are sent as press and release at once.
- Leaving the window releases everything held, so Cmd-Tab away never leaves
  Ctrl stuck in Windows.
- On ISO keyboards macOS reports the § and < keys swapped. Detected with
  `KBGetLayoutType` and corrected, as FreeRDP's own Mac client does.

"Send raw keys" sends everything as scancodes, for apps that need key
positions.

## Scrolling

AppKit's scroll deltas already follow the natural scrolling setting. A positive
deltaY means toward the top, which is what a positive Windows wheel value means
(WM_MOUSEWHEEL), so it passes straight through. Horizontal is the other way
round in Windows and gets flipped. Encoding per MS-RDPBCGR 2.2.8.1.1.3.1.1.3.

## Credentials

Passwords go straight into FreeRDP's settings, never through a command line.
Keychain access goes through `/usr/bin/security` off the main thread, with `-w`
as the last argument, and every write is read back before it is trusted.

## Why AppKit and not SwiftUI

AppKit builds with the Command Line Tools alone. Some Command Line Tools
releases ship without the plugin SwiftUI's macros need.
