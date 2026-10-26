<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

# iGateway.exe

A Remote Desktop client for the Mac, for Windows servers behind an RD Gateway
or reached directly. Built on [FreeRDP](https://github.com/FreeRDP/FreeRDP),
but it behaves like a Mac app.

![The host list](docs/screenshot.png)

## Features

- **Gateways.** Servers are grouped per RD Gateway, each with its own account.
  Servers without a gateway go under "Direct connections".
- **A Dock icon per server.** Every session is its own app, with the server's
  label on its icon in a colour you pick, so switching is one click.
- **Recent connections.** What you connected to, for how long, and why
  something failed.
- **Feels like a Mac.** Resize the window or go fullscreen and Windows follows.
  Cmd-C and Cmd-V, the Mac's scroll direction and your keyboard layout just
  work.
- **Copy and paste** text, images and files, both ways.
- **Safe by default.** Passwords go in the Keychain. A server certificate that
  neither FreeRDP nor macOS can verify is shown to you before you log in.
- Sound, a shared folder, and export and import of your server list (never
  passwords or accounts).

## Install

Runs on macOS 13 or later on an Apple Silicon Mac. Building needs the Xcode
Command Line Tools with the macOS 14 SDK or later (`xcode-select --install`).
No Homebrew.

```bash
./deps/build-deps.zsh
./build.zsh --install
```

The first command downloads FreeRDP, OpenSSL and FFmpeg's H.264 decoder,
checks each against a pinned SHA-256 and builds them. It takes about a
minute and only has to run once. The second builds the app and puts it in
`~/Applications`.

## Your data

- Servers and settings: `~/Library/Application Support/iGateway/config.json`
- Passwords: your login Keychain, only when you choose to save them
- Logs: `~/Library/Logs/iGateway`, or Window, Show Logs. Never passwords.

## Limits

- Logins use NTLM; Kerberos isn't supported.
- No smartcards, printers, microphone, USB devices or multiple monitors.
- H.264 video is decoded in software.

## What's in here

- `swift/`: the app (window, host list, sessions, clipboard, keyboard)
- `bridge/`: a small C layer between the app and FreeRDP
- `deps/build-deps.zsh`: downloads and builds FreeRDP, OpenSSL and FFmpeg
- `build.zsh`: builds the app; `release.zsh`: packs it for a release
- `tests/`: the tests, run with `tests/run.zsh`
- `icon/`: the icons and the code that draws them
- `docs/`: how it works, and the images in this README
- `.github/workflows/`: builds and tests every push on GitHub

## More

- [How it works, and why](docs/how-it-works.md)
- Tests: `./tests/run.zsh`
- License: Apache 2.0. FreeRDP and OpenSSL are Apache 2.0 too, FFmpeg's
  decoder is LGPL 2.1 or later. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
