# How it works, and why

The details behind the README. The app is AppKit plus a small C bridge
(`bridge/rdpbridge.c`) over FreeRDP's client library.

## Building

`deps/build-deps.zsh` builds three libraries as static libraries in
`deps/out`, all for Apple Silicon and macOS 13:

- **OpenSSL 3.5.9**, which FreeRDP uses for TLS, NLA and certificates.
  FreeRDP's own build files say only OpenSSL is tested on each release, and
  macOS has no OpenSSL to link against. 3.5 is OpenSSL's long-term support
  series, supported until April 2030; the series after it get 13 months.
- **FreeRDP 3.33.1**, with the client channels built in. The H.264 video
  Windows sends (AVC420 and AVC444) goes through Apple's VideoToolbox,
  FreeRDP's own decoder for it since 3.33, which leaves hardware or software
  decoding to macOS. That replaced FFmpeg: one library less to build and
  keep current, and no LGPL code in the app.
- **SwiftTerm 1.20.0**, the terminal of SSH sessions, compiled with `swiftc`
  directly: no Swift package manager, no Xcode.

It also downloads CMake to build FreeRDP; CMake is not part of the app. Each
download is checked against its SHA-256: the one the project publishes, and
for SwiftTerm, whose GitHub archive has none, the one of the archive as first
downloaded.

`build.zsh` runs it by itself when the libraries are missing, or when
`build-deps.zsh` or the Swift compiler changed since the last run:
`build-deps.zsh` leaves a stamp of both in `deps/out`.

**Keeping them current.** `deps/check-updates.sh` compares the pinned
versions with each project's latest release, and for OpenSSL also with the
latest patch release of the same series, where security fixes arrive. A
GitHub workflow runs it every Monday and opens an issue when something is
newer. Updating stays a deliberate change: the new version and its SHA-256
in `build-deps.zsh`, after which CI builds and tests it.

**Releases.** A new version in `build.zsh` is the release. On every push to
`main`, a workflow checks whether that version has a release yet. If not, it
runs all tests, packs the app with `release.zsh` and publishes release
`v<version>` with the zip and its SHA-256, and notes made from the merged
pull requests. Pushes that keep the version do nothing.

The libraries are built for the prefix `/opt/igateway` and then staged into
`deps/out`. Libraries remember their install folder, and this keeps the
builder's own folders out of the app. Nothing is ever installed in
`/opt/igateway`.

`build.zsh` compiles the bridge and the Swift sources and links everything
into one executable that only needs macOS itself. `BUNDLE_ID=...` gives your
own builds their own bundle identifier.

The app's icon is the artwork in `icon/AppIcon-art.webp`: `icon/make-icon.swift`
cuts its tile out of the black around it and puts it on Apple's icon grid.
The PC for each session is drawn there too. `icon/make-icon.zsh` rebuilds
the `.icns` files.

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
the server's name, its own bundle id and the server's id, plus a copy of the
app's executable, signed ad hoc for that bundle. It is rebuilt when the app or
the server's name changes, and removed when its server is.

A signed copy and not a link: the main app's signature covers its own
`Info.plist`, so a link in a bundle with a different one has a broken
signature, and macOS then refuses the session the Desktop, Documents and
Downloads folders without asking. That shows up in Windows as an empty shared
folder and "The device is not connected". With its own signature, macOS asks
instead. A symlink doesn't work either: one started by LaunchServices
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

## When a connection fails

FreeRDP's final error code often names the wrong step: a rejected gateway
login can surface as "security negotiation failed". So the bridge routes
FreeRDP's log through a callback (still written to `freerdp.log`) and reads
along:

- the gateway tunnel's state changes, which FreeRDP logs as
  `TSG_STATE_X -> TSG_STATE_Y`: started, signed in, allowed by policy, server
  reached, ready;
- the gateway's own reason codes (`E_PROXY_*`), such as "not allowed to that
  server" or "couldn't reach the server";
- sign-in errors, with how far the gateway was at that moment.

At the failure it adds FreeRDP's connection state and error code.
`swift/Failure.swift` turns that into one step that failed (reach the gateway,
sign in to it, its policy, the gateway reaching the server, sign in to the
server, start the session) and a plain sentence. The window shows the steps
with what succeeded; Copy Details puts the technical summary on the
clipboard.

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

## SSH sessions

An SSH host runs the Mac's own `/usr/bin/ssh` in a terminal view from
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), in the host's own
session app like a Remote Desktop session. Using the system's ssh means keys,
the agent, `known_hosts` and certificates work as they do in Terminal, and no
SSH or crypto code of our own is involved. Everything filled in on the host
(user, port, key, jump host) is passed to ssh on its command line.

What iGateway adds is a stricter frame around it:

- **Passwords never go through the terminal.** A server can send a banner
  before login that looks exactly like ssh's password prompt, and a password
  typed into that would end up in the remote shell. So iGateway never types
  one. Instead ssh runs with `SSH_ASKPASS_REQUIRE=force` (`ssh(1)`,
  ENVIRONMENT): it doesn't read passwords from the terminal but runs a helper,
  which is iGateway's own executable. The helper asks the session over a
  socket in a folder only you can open, and prints the answer for ssh. ssh
  only runs it when its own login needs an answer, so a server's text can't.
- **Saved passwords** come from the Keychain, and only for ssh's own password
  prompt for exactly the host's, or its jump host's, user@address. Anything
  else ssh asks (a new host key, a key's passphrase, a one-time code) is shown
  as a sheet with ssh's own text. A password is saved only when you tick the
  box, per user, server and port. When ssh asks again in the same session, the
  saved one was refused: it's deleted and you're asked. The socket answers
  only a process started by that session's ssh (checked by its parent
  process) that also has the session's random token.
- **Fixed options.** Every session runs
  `ssh -o ForwardAgent=no -o ForwardX11=no -o StrictHostKeyChecking=ask
  [-p port] [auth options] -- [user@]host`. Options on the command line win
  over `~/.ssh/config`, so a config can't loosen these (the unit tests check
  this against the real ssh with `ssh -G`).
- **Key or certificate by default.** Such a host also gets
  `PasswordAuthentication=no` and `KbdInteractiveAuthentication=no`, so ssh
  never asks for a password, and a fake server can't make it. A chosen key
  file adds `-i <file> -o IdentitiesOnly=yes`; ssh also picks up a
  certificate next to it (`<file>-cert.pub`). A host set to "Password" lets
  ssh ask in the terminal, every time.
- **No way to sneak in an option.** The address and user are checked (no
  leading dash, no spaces or control characters) and `--` ends ssh's options
  before the destination. Imported host lists go through the same check.
- **A small environment.** ssh gets `TERM`, `PATH`, `HOME`, `USER`,
  `LOGNAME`, `LANG` and `SSH_AUTH_SOCK`, nothing else from the app.
- **What the server can make the Mac do.** SwiftTerm's own process view lets
  the server read and write the clipboard (OSC 52), so the session uses its
  base view with its own small wrapper instead. The server can't touch the
  clipboard, can't change the window title, and gets no answer to title
  queries. Links open only for http and https, after showing the address.
  Pasting several lines into a program that doesn't mark pastes (bracketed
  paste) asks first, because the server runs each line as it arrives.
- **Logs** get the ssh command line, start and exit code, never what goes
  through the terminal.

**Jump hosts.** An SSH host's Jump host field goes to ssh as `-J`
(`ssh(1)`): ssh logs in to the jump host first and goes on from there. The
jump host only passes the encrypted connection through: it never sees the
target's password or your keys, as agent forwarding stays off. Both host keys
are checked. Hosts with the same jump host are grouped under it in the
sidebar; the group comes and goes with them. One limit, from the man page:
options on the command line apply to the target, not the jump host.

ssh exits with the remote command's status, or 255 when it couldn't connect
or log in (`ssh(1)`, EXIT STATUS). A 255 keeps the window open on ssh's
message and shows as failed in Recent; anything else closes it, like signing
out of Windows. SSH hosts never go through an RD Gateway, which only carries
Remote Desktop.

### Keys and certificates

Logging in with a key, or better a certificate, is safer than a password.
None of this needs anything from iGateway: it is how OpenSSH works, and the
details are in the man pages named.

- **A key per admin.** An ed25519 key with a passphrase, kept in the Keychain
  with `ssh-add --apple-use-keychain`, and its public key on the servers.
- **User certificates.** A CA key signs each admin's public key with
  `ssh-keygen -s` (`-I` who it is, `-n` the accounts it may log in as, `-V`
  how long it is valid). Servers trust the CA once with `TrustedUserCAKeys`,
  and `AuthorizedPrincipalsFile` says who may log in as what. No
  `authorized_keys` on every server, certificates expire by themselves, and
  `RevokedKeys` blocks one early. See `ssh-keygen(1)`, CERTIFICATES, and
  `sshd_config(5)`.
- **Host certificates.** The same CA signs the servers' host keys. One
  `@cert-authority` line in `known_hosts` then trusts them all (`sshd(8)`,
  SSH_KNOWN_HOSTS FILE FORMAT), so there is no "are you sure" on a first
  connect, and a server that isn't the real one stands out.

## Why AppKit and not SwiftUI

AppKit builds with the Command Line Tools alone. Some Command Line Tools
releases ship without the plugin SwiftUI's macros need.
