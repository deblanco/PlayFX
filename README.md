<p align="center">
  <img src="apps/desktop/src-tauri/icons/icon.png" alt="PlayFX icon" width="160">
</p>

# PlayFX

A PS5 / PS4 Remote Play client for macOS. It streams your console to the Mac with hardware HEVC
decoding, Metal + MetalFX upscaling, HDR on XDR displays, and full DualSense support: rumble,
adaptive triggers, touchpad and motion.

> PlayFX is an independent project. It is not affiliated with, endorsed by or sponsored by Sony
> Interactive Entertainment. "PlayStation", "PS5" and "DualSense" are trademarks of their owners.

## Features

- **Connect:** finds consoles on the local network, wakes them from rest, pairs with a PIN, and plays
  over the internet through PSN when the local network can't reach the console.
- **Video:** H.264 and HEVC decoded with VideoToolbox, MetalFX spatial upscaling (optional Apple ML
  super-resolution), HEVC HDR10 shown in EDR, optional frame interpolation.
- **Audio:** low-latency playback with output device and volume choice; a microphone for voice chat.
- **Controllers:** DualSense, DualShock 4, Xbox and MFi pads through GameController, with rumble, adaptive
  triggers, touchpad and motion. The Mac keyboard works as a controller, and the trackpad works as the
  touchpad (hold ⌥ Option).
- **Status:** an on-screen stats line (frame rate, bitrate, latency, lost frames); pairing keys are
  kept in the macOS Keychain (release builds).

See [PLAN.md](PLAN.md) for what's verified on hardware and what's next.

## Layout

```
apps/desktop            Tauri v2 app: React + Effect + Tailwind/shadcn UI in a transparent webview
                        over a native Metal view; Rust bridge to StreamCore.
packages/streamcore     Swift package: libchiaki session, VideoToolbox decode, Metal/MetalFX,
                        audio, controller input. Also the `psrp` CLI for headless debugging.
third_party/chiaki-ng   Submodule (AGPL-3.0): the Remote Play protocol implementation.
```

## Setup

Requires an Apple silicon Mac, Xcode, [Bun](https://bun.sh), Rust (stable) and Homebrew.

```sh
git clone --recursive git@github.com:deblanco/PlayFX.git
cd PlayFX
brew install cmake ninja protobuf openssl@3 opus json-c miniupnpc libevent
packages/streamcore/scripts/build-chiaki.sh   # once, and after bumping the submodule
bun install
bun run desktop                               # run the app (dev)
bun run desktop:build                         # build the .app
```

## Checks

Every package keeps line, branch and function coverage at or above 80%.

```sh
bun run --cwd apps/desktop check                       # tsc, ESLint, vitest + coverage
packages/streamcore/scripts/coverage.sh                # Swift tests + coverage
bun run --cwd apps/desktop coverage:rust               # Rust (cargo llvm-cov)
```

## Debugging without the app

`psrp` drives StreamCore headlessly:

```sh
cd packages/streamcore && swift build --product psrp
.build/debug/psrp discover
.build/debug/psrp register --host 192.168.1.20 --pin 12345678
.build/debug/psrp stream          # control API on http://127.0.0.1:7777 (/status, /snapshot.png, /press…)
.build/debug/psrp pad             # the Mac's controller without a console: live state, rumble, triggers
```

Pairing keys are saved to `~/.config/psrp/config.json`. Keep that file private.

## License

PlayFX is free software under the [GNU AGPL-3.0](LICENSE). It links
[chiaki-ng](https://github.com/streetpea/chiaki-ng) (AGPL-3.0), so every build you distribute must
come with its complete source. The app links to it under Settings → Diagnostics → Source code.
[NOTICE](NOTICE) lists the third-party code that is linked in.

## Sony and PlayStation Network

PlayFX is an unofficial client for your own consoles and your own PlayStation account. It talks to the
console with the same Remote Play protocol as Sony's app. It signs in to PSN only through Sony's own
sign-in page, and keeps the result on your Mac. No credentials ship with PlayFX, and none are sent
anywhere else. Using it is subject to Sony's terms for PlayStation Network.
