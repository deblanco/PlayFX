# PlayFX Help

How to set up PlayFX, answers to common questions, the keyboard controls, and where to get more help.
PlayFX plays your PlayStation 5 or PlayStation 4 on your Mac. It isn't made by Sony.

- [Requirements](#requirements)
- [First-time setup](#first-time-setup)
- [FAQ](#faq)
- [Keyboard as controller](#keyboard-as-controller)
- [What PlayFX stores, and where](#what-playfx-stores-and-where)
- [Logs and bug reports](#logs-and-bug-reports)
- [Uninstall or start over](#uninstall-or-start-over)
- [More help](#more-help)

## Requirements

- **A Mac with Apple silicon** (M1 or later) on **macOS 13** or later.
- **macOS 26** for frame interpolation and ML upscaling. Everything else works on macOS 13.
- **A PS5 or a PS4.** Pairing without a code and playing over the internet work with a PS5 only.
- **A PlayStation Network account**: the one you use on the console.
- **A network:**
  - At home, the Mac and the console on the same network. The best setup is the console on a cable and
    the Mac on 5 GHz or 6 GHz Wi-Fi.
  - Away from home, an internet connection at both ends. With Bitrate on Auto, a 1080p stream uses
    about 15 Mbps.

## First-time setup

### 1. On the console

**PS5:**

1. Settings › System › Remote Play › turn on **Enable Remote Play**.
2. So PlayFX can wake it from rest mode, open Settings › System › Power Saving › Features Available in
   Rest Mode and turn on **Stay Connected to the Internet** and **Enable Turning On PS5 from Network**.

**PS4:** Settings › Remote Play Connection Settings › **Enable Remote Play**. For waking from rest mode,
Settings › Power Save Settings › Set Features Available in Rest Mode: turn on **Stay Connected to the
Internet** and **Enable Turning On PS4 from Network**.

### 2. Sign in

Open PlayFX and choose **Sign in with PlayStation**. Sony's own sign-in page opens in a window. You only
do this once. Sign in with the account of the console user you'll
play as.

### 3. Pair

Pairing lets the console trust this Mac. You do it once per console.

- **Without a code (PS5 only):** once you're signed in, your account's PS5s show **Pair (no code
  needed)**. Choose it and wait 20 to 30 seconds. There's nothing to do on the PS5. It works whether the
  PS5 is on this network or not.
- **With a code:** on the PS5, open Settings › System › Remote Play › **Pair Device** (called **Link
  Device** on some versions). On a PS4, Settings › Remote Play Connection Settings › **Add Device**. In
  PlayFX, choose **Pair** (or **Pair with a code**) next to the console and type the **8-digit code**
  the console shows. The code is valid for about 5 minutes, so keep that screen open while you type it.
  The console must be on the same network as the Mac.

### 4. Play

Press **Play**. If the console is in rest mode, PlayFX wakes it first. When you press **Stop**, PlayFX
asks whether to put the console in rest mode or leave it on.

### Playing over the internet

Once a PS5 is paired and you're signed in, you can play it away from home. **Connect** on the home screen
chooses how Play reaches the console:

- **Automatic** (the default): your home network first, and through PSN if the console can't be reached
  there.
- **Home network:** only on your home network. Fastest to connect.
- **Internet:** always through PSN, even at home. It takes 20 to 40 seconds to connect.

If the home screen says "To play away from home, sign in with PlayStation once more", sign in again:
PlayFX needs a fresh PSN sign-in for internet play.

## FAQ

### PlayFX doesn't find my console

While PlayFX looks, the list says "Looking for consoles on this network…". If nothing shows up, check:

- **The console is on, or in rest mode** with Stay Connected to the Internet turned on.
- **Same network:** the Mac and the console are on the same network. A guest Wi-Fi usually keeps devices
  apart, so use your main network.
- **No VPN** is on on this Mac.
- **Local Network permission:** the first time, macOS asks whether PlayFX may find devices on your local
  network. If you chose Don't Allow, use **Open Local Network settings** in PlayFX (or System Settings ›
  Privacy & Security › Local Network) and turn PlayFX on.
- **Another subnet:** if the console is behind a second router, or on another part of the network, type
  its address in **Console IP address**. Find it on the PS5 in Settings › Network › Connection Status.
  With consoles already listed, the field is under "Console missing? Add it by IP". PlayFX asks that
  address on every scan.

Away from home, the console won't show up on the local network. Play a paired PS5 with Connect ›
Internet instead.

### Pairing failed. What does the message mean?

PlayFX says why pairing failed and what to do next:

| Message starts with | What to do |
|---|---|
| "The code is wrong or has expired." | Check the digits, or close and reopen Pair Device (Add Device on a PS4) for a new code, and type it within about 5 minutes. |
| "The PlayStation account ID PlayFX used doesn't belong to the PS5 user who opened Pair Device." | The code was made by a different console user than the account you signed in with. Open Pair Device as your own user, or sign in to PlayFX as that user. |
| "The PS5's Remote Play version doesn't match PlayFX's." | Update the console's system software and PlayFX, then pair again. |
| "The PS5 stopped answering partway through pairing." | Keep Pair Device open on the console and pair again with the code it shows. |
| "The PS5 didn't answer." | Keep Pair Device open while you pair, and check that the console is on the same network as the Mac. |
| "Couldn't reach the PS5." | Allow PlayFX in System Settings › Privacy & Security › Local Network, and turn off any VPN. |
| "Registration failed: check the PIN…" | Something else went wrong. Get a new code and try again, with the console on and on the same network. |

Pairing without a code (through PSN) has its own messages:

| Message | What to do |
|---|---|
| "The PS5 didn't answer through PSN." | Check the PS5 is on, or in rest mode with Stay Connected to the Internet on, and try again. |
| "The PS5 didn't accept pairing through PSN." | Check that Remote Play is on, and that you signed in with the account of the PS5 user. |
| "PSN didn't finish pairing in time." | Check the PS5 is on, and try again. |
| "Remote Play is off on …" | On the PS5, turn on Settings › System › Remote Play › Enable Remote Play. |

If pairing without a code doesn't work, PlayFX offers pairing with a code instead. For that the console
has to be on this Mac's network.

### Pairing code or console passcode?

They're different:

- The **pairing code** has 8 digits. The console shows it in Pair Device (Add Device on a PS4), only when
  you pair.
- The **console passcode** has 4 digits. It's the passcode your console user may have set to log in. If
  you have one, PlayFX asks for it ("Console passcode") when a stream starts. Type the passcode, not the
  pairing code.

### Waking the console from rest mode

Press **Play** on a console in rest mode: PlayFX wakes it, waits until it's ready, then plays. **Wake**
only wakes it. The console takes about 20 seconds to start. For this to work, the console needs Stay
Connected to the Internet and Enable Turning On PS5 from Network (see [setup](#1-on-the-console)).

If the wake-up can't get through the home network and you're signed in, Automatic connects through PSN
instead, which wakes the console too.

### What is Steady Wi-Fi, and why does it ask for my password?

AirDrop and Handoff share the Mac's Wi-Fi radio. About once a second they take it off your network for
about 90 ms, and the stream stalls with it. **Steady Wi-Fi** (on the home screen and in Settings › Stream)
pauses AirDrop, Handoff, Universal Control and wireless Sidecar while PlayFX is open. Measured with a PS5
over Wi-Fi, the worst stall went from about 100 ms to 21 ms.

Pausing them needs administrator rights, so macOS asks for your password (or Touch ID) each time you turn
it on. They come back when you turn it off or quit PlayFX, even if PlayFX crashes. PlayFX remembers that
you turned it on, and offers it again (with the same prompt) when the next stream starts. If you dismiss
the prompt, it doesn't ask again until you reopen PlayFX.

While playing, "AirDrop is stalling the Wi-Fi" at the top means it's off and hurting the stream right
now; **Turn on Steady Wi-Fi** is right there.

### The stream stutters, or the picture hops

- Turn on **Steady Wi-Fi** (above). It's the most common cause on Wi-Fi.
- Put the console on a cable, and the Mac on 5 GHz or 6 GHz Wi-Fi, on the same network.
- Lower the Resolution or Bitrate in Settings › Stream, and keep **Lower resolution when the network is
  slow** on.
- Turn on **Stats on screen** (Settings › Picture) and watch the lost frames, the skipped frames and the
  ping (see below).

If the connection drops, the network changes, or the picture stops while the sound goes on, PlayFX
reconnects by itself, up to 3 times in a row. After that it goes back to the home screen and says why.

### What does the stats line say?

Turn it on with **Stats on screen** in Settings › Picture. Numbers in amber point to a problem.

| Item | Meaning |
|---|---|
| `1920×1080` | The resolution the console sends. `(asked 1080p)` in amber: the console lowered it because the network was slow. |
| `60 fps` | The stream's frame rate. `30 fps game · 60 fps stream` when the game runs slower than the stream; `· 120 shown` when frame interpolation adds images. |
| `12.4 Mbps (target 19.4)` | The video bitrate received, and what the console's encoder aims for. Well below the target usually means the picture doesn't need more. |
| `ping 12 ms` | The round trip to the console. Amber from 60 ms. |
| `GPU 2.9 ms` | The Mac's graphics time per frame. Amber from 8 ms. |
| `latency 20 ms` | Decoding plus waiting for the screen, on the Mac (the network's part is the ping). Amber from 33 ms. |
| `MetalFX` | The upscaler at work: `MetalFX`, `Bilinear`, or `ML + MetalFX` with ML upscaling. `(no upscale needed)` when the stream is already as large as the window. |
| `ML idle (…)` | ML upscaling is on but not used, and why (only for 720p and lower, not for HDR, unavailable on this Mac). |
| `+30 generated` | Frame interpolation: images made between the game's frames each second. |
| `(2/s missed)` | Pairs of frames per second that got no image in between, so the picture held for a moment. Amber from 3 a second. |
| `no interpolation: …` | Frame interpolation is on but idle, and why: for example `60 fps on a 60 Hz screen` (nothing to fill), or `still picture`. |
| `HDR` | The stream is in HDR. |
| `0 lost frames` | Frames that never arrived from the network, over the whole stream. Amber above 0. |
| `2/s skipped` | Frames per second that arrived but were never shown, because the next one was already due (the picture jumps ahead). Amber from 1 a second. |
| `decode errors` | Frames the Mac couldn't decode. |

### What does frame interpolation do?

It makes images between the game's own frames, one for each screen refresh. A 30 fps game looks like
60 fps on a 60 Hz screen, and like 120 on a ProMotion screen, even inside a 60 fps stream. It's off by
default; turn it on in Settings › Picture.

- It runs only when the screen refreshes at least 1.2 times as often as the game: a 60 fps game on a
  60 Hz screen gets nothing (the stats say so).
- It needs macOS 26, and sits out in HDR.
- **The cost is latency:** at 30 fps, frames show about 40 ms later. It suits slower games; for fast
  games, 60 fps without interpolation feels more responsive.

### Upscaling and ML upscaling

The console sends at most 1080p. PlayFX enlarges each frame to your window with **MetalFX** (the
default), then sharpens it. **ML upscaling first** (Settings › Picture) runs Apple's neural upscaler
before that: the biggest gain at 720p (crisper hair and edges), for about 5 ms of latency. It needs
macOS 26, works on 720p and lower streams, and sits out in HDR.

Picture settings change the video right away. Set **View** to **Split** in Settings › Picture to see the
stream as it arrives on the left and with your settings on the right.

### HDR

Turn on **HDR** in Settings › Stream (it needs the HEVC codec), and turn on HDR in the PS5's screen
settings too. On a Mac screen that shows HDR (such as a MacBook Pro's XDR display), highlights go
brighter than white. PlayFX switches back to SDR by itself for SDR games. Frame interpolation and ML
upscaling sit out in HDR.

### Bitrate, stream settings and profiles

- **Picture** settings (Settings › Picture) apply to the video right away.
- **Stream** settings (Settings › Stream: Resolution, Frame rate, Codec, HDR, Bitrate, Lower resolution
  when the network is slow, Sound) apply the next time you connect. While playing, **Reconnect** appears
  when one changed. A Bitrate change alone reconnects by itself after a moment.
- **Bitrate:** Auto lets the console decide (about 15 Mbps at 1080p). Higher, up to 50 Mbps, keeps more
  detail in motion.
- **Profiles** keep a set of stream and picture settings under a name. **Recommended** (1080p60 ·
  MetalFX · sharpness 0.3) is built in; **Save as…** saves your own. Pick a profile on the home screen or
  in Settings. While playing, each profile says whether it **applies now** (picture settings only) or
  **needs a reconnect** (stream settings).

### DualSense: rumble, adaptive triggers, haptics and the light bar

A DualSense works over USB or Bluetooth, with rumble, adaptive triggers, the touchpad and motion.

- **Real haptics over USB:** PS5 games drive the DualSense's motors with sound. With the controller on a
  USB cable, PlayFX plays that sound on the motors, so you feel what the game was made with. Set it up
  once: open **Audio MIDI Setup** (in Applications › Utilities), select the DualSense, and set its output
  to **4 channels (Quadraphonic)**. Left at 2 channels, you get rumble instead.
- **Over Bluetooth**, PlayFX sends the haptics to the controller too (not yet confirmed on a real
  controller). If that can't start, you get rumble.
- **The light bar** follows the game (a colour per character, red and blue in a police chase), and so
  does the player number.
- When PlayFX quits, it stops any rumble, trigger effect and haptics first, so the controller doesn't
  keep playing them.
- **The PS button:** macOS keeps the controller's PS button for itself. Use the **PS** button at the
  bottom of the stream, or the **P** key. A short press opens the control center; holding it goes home.

### Microphone

Press **Mic** at the top of the stream to talk in voice chat. The first time, macOS asks whether PlayFX
may use the microphone. Your voice goes to the console only while the microphone is on; "Mic on" stays
on screen while it is. If PlayFX can't use it, allow it in System Settings › Privacy & Security ›
Microphone. Headphones keep the game's sound out of your microphone.

### Other controllers, and typing

DualShock 4, Xbox and other controllers that work with macOS work too, through macOS's game controller
support. The Mac's keyboard works as a controller (see [below](#keyboard-as-controller)).

When the console asks you to type (a search, a message), a text bar appears at the bottom of the stream.
Type on the Mac; Return sends, Esc cancels.

## Keyboard as controller

The Mac's keyboard works as a controller while you play. **Keys** at the top of the stream shows this
list too.

| Key | Controller |
|---|---|
| Enter / Space | ✕ |
| Backspace | ◯ |
| Q / E | □ / △ |
| Arrows | D-pad |
| W A S D | Left stick |
| I J K L | Right stick |
| 1 / 2 | L1 / R1 |
| 3 / 4 | L2 / R2 |
| Z / X | L3 / R3 |
| Tab / Shift | Options / Share |
| P / T | PS / Touchpad |
| ⌥ + pointer | Touchpad finger |
| ⌥ + click | Press touchpad |

**The trackpad as the touchpad:** hold **⌥ Option** and the pointer becomes a finger on the controller's
touchpad, over the video. Move it to swipe; click to press the touchpad. Let go of ⌥ to use the pointer
normally again.

## What PlayFX stores, and where

- **In the macOS Keychain:** the pairing keys for your consoles and your PSN account ID (under
  "PlayFX"), and your PlayStation sign-in (under "PlayFX — PSN"). Only PlayFX reads them. macOS doesn't
  ask you before PlayFX reads its own Keychain items.
- **In PlayFX's own storage on the Mac:** your settings, profiles, the console IP you typed and whether
  Steady Wi-Fi is on.
- **In its log:** what happened, for bug reports (see below). Logs never contain your PlayStation
  sign-in, pairing keys or account ID.
- **Nothing is sent anywhere but your console and Sony.** PlayFX talks to the console, and to
  PlayStation Network to sign in, list your consoles and connect over the internet. You sign in on
  Sony's own page.

**The only password prompt to expect is Steady Wi-Fi's**, because pausing AirDrop and Handoff needs
administrator rights. macOS also asks once for permission to use the local network (to find your
console) and, if you turn it on, the microphone. Those are permission questions, not passwords.

## Logs and bug reports

Open **Settings › Diagnostics**:

- The first line is the version, for example "PlayFX 0.2.0 (abc1234) on macOS 26.1". Include it in a bug
  report.
- **Detailed logs** records much more. Turn it on, make the problem happen, then turn it off.
- **Copy diagnostics** copies a report (versions, what your Mac supports, your settings and the last
  200 lines of the log) to paste into a bug report.
- **Open logs folder** shows the log in Finder (`~/Library/Logs/dev.deblanco.playfx`).
- **Help** opens this page.

Report a bug or ask a question at
[github.com/deblanco/PlayFX/issues](https://github.com/deblanco/PlayFX/issues).

## Uninstall or start over

- **Forget a console:** **Forget** next to it in PlayFX. The console keeps the Mac in its list of
  paired devices until you remove it there.
- **Sign out of PSN:** **Sign out** on the home screen.
- **Uninstall:** quit PlayFX and drag it from Applications to the Trash. To remove what it kept too:
  - In Keychain Access, delete the items named "PlayFX" and "PlayFX — PSN".
  - Delete `~/Library/WebKit/dev.deblanco.playfx` and `~/Library/Caches/dev.deblanco.playfx` (settings
    and profiles).
  - Delete `~/Library/Logs/dev.deblanco.playfx` (logs).

## More help

- [README](../README.md): what PlayFX does, the picture settings in detail, building from source.
- [Network](NETWORK.md): what makes a stream stutter on the network, and what PlayFX does about it.
- [Frame interpolation](FRAME_INTERPOLATION.md): how it works and what was measured.
- [Releases](https://github.com/deblanco/PlayFX/releases): the latest version.
- [Issues](https://github.com/deblanco/PlayFX/issues): bug reports and questions.
