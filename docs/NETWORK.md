# Network

What makes a Remote Play stream stutter between the PS5 and the Mac, what we measured, and what PlayFX
does about it. Frame pacing and interpolation, which turn network jitter into smooth motion on screen,
are in [FRAME_INTERPOLATION.md](FRAME_INTERPOLATION.md).

## The short version

- **AirDrop and Handoff stall the Mac's Wi-Fi once a second.** They run over AWDL, a peer-to-peer Wi-Fi
  link. To listen for nearby Apple devices, the Mac's one radio leaves your network's channel for about
  90 ms each second. The **Steady Wi-Fi** switch, on Home and in Settings → Stream, pauses them while
  PlayFX is open. PlayFX remembers it's on, and while streaming the HUD warns when AirDrop is stalling,
  or when the stream's frames show the stall.
- **libchiaki comes from our fork**, [deblanco/chiaki-ng](https://github.com/deblanco/chiaki-ng), branch
  `playfx`. It carries fixes for false packet loss, a too-small receive buffer, Wi-Fi priority marking and
  dropped acks. PlayFX also runs libchiaki's receive and input threads at the highest scheduling class.
- **The best network is the simple one:** the Mac and the PS5 on the same network (same router, same
  subnet), the PS5 wired, the Mac on 5 or 6 GHz.

## AirDrop, Handoff and the once-a-second stall

### What happens

AWDL (Apple Wireless Direct Link) is the peer-to-peer Wi-Fi behind several features:

- AirDrop,
- Handoff,
- Universal Control,
- AirPlay to nearby devices,
- wireless Sidecar.

The Mac has a single Wi-Fi radio. While AWDL is up, the radio regularly leaves your network's channel to
listen on AWDL's channel. A video stream feels each of these trips as a stall: packets wait, then arrive
in a burst.

### What we measured

The setup: a MacBook Pro on Wi-Fi 6 (5 GHz, 160 MHz, −53 dBm), and the PS5 on another subnet behind a
second router. There were 300 pings at 50 ms intervals; for the AWDL-on rows the stream wasn't running.

| Ping to | AWDL | Spikes over 40 ms | Worst | 99th percentile | Typical |
|---|---|---|---|---|---|
| The Mac's router | on | 17 of 300, **one every second** | 98 ms | 88 ms | 9.3 ms |
| The Mac's router | off | 0 | 37 ms | 19 ms | 8.6 ms |
| The PS5 | on | about one per second | 105 ms | — | ~20 ms |
| The PS5 | off | 0 | **21.5 ms** | 20.7 ms | 14.6 ms |

The spikes came every 19–20 pings, like clockwork, and vanished with `sudo ifconfig awdl0 down`. A
wireless Sidecar iPad wasn't the cause: disconnecting it changed nothing while AWDL stayed up. AirDrop,
Handoff and Universal Control keep AWDL up on their own.

### Steady Wi-Fi: how PlayFX pauses it

Switching AWDL off needs administrator rights, and macOS switches it back on by itself within minutes.
So a one-off command isn't enough. `PeerWifi` (`packages/streamcore/Sources/StreamCore/PeerWifi.swift`)
works like this:

1. **Ask once.** Turning the switch on runs one AppleScript `do shell script … with administrator
   privileges`, with a prompt that says why. macOS shows its password (or Touch ID) dialog.
2. **A small helper keeps it off.** The script starts a root `sh` loop in the background:

   ```sh
   while [ -e $TMPDIR/playfx-awdl-<pid> ] && /bin/kill -0 <pid> 2>/dev/null; do
     /sbin/ifconfig awdl0 down; /bin/sleep 0.5
   done; /sbin/ifconfig awdl0 up
   ```

   When macOS brings AWDL back, it's off again within half a second.
3. **It ends on its own.** The loop stops and switches AWDL back on as soon as either of these happens:
   - the marker file is gone, because the user turned the switch off, with no second password prompt;
   - PlayFX's process has ended (a quit or a crash).

   A crash therefore never leaves AirDrop off.

**Safety.** The root command is built only from fixed text, the process ID and the marker's path. Nothing
from the user, a file or the network goes into it, and the path is refused unless it's plain letters,
digits and `/._-`.

The marker lives in the user's own temporary folder, not the shared `/tmp`, where another account could
create or hold the name. The root side only ever tests whether it exists; it never reads or writes it.
It's per process, so a crashed run's leftover can't make a new run think it's paused, and two copies of
PlayFX can't stop each other's helper. PlayFX removes it when it exits.

**State while changing.** The password prompt can stay open for minutes. While it is, the state still
reads `active`, even though the marker already exists for the helper's first check. Turning the switch off
waits (up to 1.5 s) until the helper has brought AWDL back, so the reply isn't the moment in between.

Asked to pause, PlayFX pauses even when AWDL reads as off at that instant, because macOS turns it off and
on by itself. The Home row and the Settings section share one state, so a change started in one disables
the other.

**State.** `PeerWifi.state` reads `awdl0`'s `IFF_UP` flag (no rights needed) and our marker:

| State | Meaning |
|---|---|
| `absent` | No AWDL on this Mac. |
| `active` | On, and stalling the Wi-Fi. |
| `off` | Off, but not by PlayFX. |
| `paused` | Kept off by PlayFX. |

The UI polls the state every 3 s, because macOS changes it underneath. The same poll runs while
streaming.

**While paused**, AirDrop, Handoff, Universal Control and wireless Sidecar don't work. The switch says
so, and switching it off brings them back at once.

**Remembered.** The pause can't outlive PlayFX, so after a relaunch AWDL is on again. PlayFX therefore
remembers the choice instead (`psrp.steadyWifi` in the webview's storage, decoded as a yes/no; anything
else reads as no). Turning the switch on saves yes once the pause is done; turning it off by hand saves
no. With yes saved, pressing Play while AWDL reads `active` asks for the password again, the same prompt
as the switch. It isn't asked at launch, only when a stream starts. The stream starts at the same time
and doesn't wait for the answer. If the prompt is dismissed (or fails), PlayFX doesn't ask again until the
next launch, and the saved choice stays yes.

### The UI

- **Home:** a row appears while AWDL is on or paused. A line of light runs from the Mac to the console.
  While AWDL is on, the flow halts for a beat every second and then surges to catch up. That's the real
  stall: packets wait, then arrive in a burst. Paused, it flows evenly and glows, and a light crosses it
  once. (A first version blinked the whole line instead, which read as a rendering glitch.)
- **Settings → Stream:** the same switch, with the measurement and what pausing costs.
- **While streaming:** when AWDL reads `active` (and not while connecting or reconnecting), the HUD shows
  "AirDrop is stalling the Wi-Fi" in the warning colour, with a "Turn on Steady Wi-Fi" button. It stays
  when the rest of the HUD fades, like the stats, because it explains a stuttering stream. It's gone once
  AWDL reads `paused`, `off` or `absent`, unless the stream itself shows the stall (below).

The code is in `apps/desktop/src/app/SteadyWifi.tsx`.

### Seeing the stall in the stream

AWDL's state is read every 3 s, and macOS turns it on and off by itself, so a reading of `off` doesn't mean
the stream isn't stalling. The stream shows it directly: frames stop, then the held ones arrive in a burst,
at the radio's steady rhythm. `StallPattern` (`FramePacing.swift`) watches every decoded frame's arrival,
before ML upscaling:

- **A gap** counts when frames stop for 70–400 ms and the next one is the very next frame. When frames were
  lost across the gap (the stream's frame numbers jump), it's packet loss, which Steady Wi-Fi doesn't fix,
  and it doesn't count. Longer gaps aren't the radio's ~90 ms trips.
- **The pattern** is at least nine gaps in the last 12 s, spaced 0.3–1.2 s apart (the median spacing), with at
  least 85% of the spacings within 12% of the median or of twice it (a stall too short to see now and then).
  A stall every second shows as the pattern about 8 s after it starts, still with each stall 30 ms early or
  late. It ends once the gaps no longer meet that, about 4 s after the stalls stop.
- **False positives:** in the tests, a single hiccup, a loss burst and ordinary jitter (frames up to 40 ms
  late) don't make the pattern. Nor do the same stalls at random times: 200 seeded minute-long runs with them
  0.2–2.5 s apart, and 200 with them 0.5–1.5 s apart, flag none (the test allows 1%). A longer simulation
  of 5,000 runs each puts the rate at about 0.2% and 1% of minute-long runs. Looser limits (six gaps in
  8 s, within 20%, 80% steady) flagged most of these runs.

The renderer reports it as `wifiStalls` in the pacing stats ([dev-control.md](dev-control.md)), and logs
when it starts (with its period) and ends. The HUD then:

| AWDL reads | Stall in the stream | HUD |
|---|---|---|
| `active` | either | "AirDrop is stalling the Wi-Fi", with "Turn on Steady Wi-Fi" (as before) |
| `off` | yes | "The Wi-Fi keeps stalling", with "Turn on Steady Wi-Fi": AWDL may only be off for the moment |
| `paused` | yes | nothing: Steady Wi-Fi is already on, and there's nothing more PlayFX can offer; the log has it |
| `absent` | yes | nothing: no AWDL to pause; the log has it |
| anything else | no | nothing |

A stall seen with Steady Wi-Fi on isn't AWDL; the log line is the evidence to look for (see "Network
layout" for what helps).

### By hand

```sh
ifconfig awdl0 | grep status        # active / inactive
sudo ifconfig awdl0 down            # off until macOS brings it back
sudo ifconfig awdl0 up
```

The lasting fix is to set AirDrop to "No One" and turn off Handoff and Universal Control in System
Settings. Moonlight and Steam Link users on Macs get the same advice.

## libchiaki: our fork

The Remote Play protocol comes from [chiaki-ng](https://github.com/chiaki-ng/chiaki-ng). PlayFX builds it
from [deblanco/chiaki-ng](https://github.com/deblanco/chiaki-ng), branch `playfx`:

- `main` mirrors upstream;
- `playfx` is upstream plus one commit per fix.

The submodule follows `playfx` (`.gitmodules`). The fixes, each meant to be offered upstream:

| Fix | Why |
|---|---|
| **No false packet loss when the sequence number wraps, or for duplicates** (`packetstats.c`, with tests) | The 16-bit difference was taken as a negative `int`. Every ~11 minutes one stats window reported about 100% loss, and that figure goes into the congestion report sent to the console. Upstream PR #871 was closed in favour of a future rewrite. |
| **4 MB receive buffer** instead of 100 KB (`takion.c`) | One large keyframe is more than 100 KB, so a short stall of the receive thread, or a Wi-Fi burst after one, dropped packets. From upstream PR #817. |
| **Real-time marking on Apple platforms**, and `TCP_NODELAY` for the control connection (`takion.c`, `ctrl.c`) | `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_RV` ("responsive audio/video, e.g. screen sharing") sends our packets with Wi-Fi WMM video priority: acks, feedback and controller input. From PR #817. |
| **Accept data acks with gap blocks** (`takion.c`) | The size check wanted exactly 12 bytes, so every ack with gap blocks was dropped, and its cumulative ack with it. From PR #817. |
| **Retry the control request when the console resets the connection** (`ctrl.c`) | The console can reset the control connection while it's still getting ready after the session request, and that failed the whole session. Now the request is resent on a new connection up to 3 times, 35 ms apart; a stop cancels the wait at once. A timeout is still retried once, as upstream does. From neo773's fork (below). |
| **One setup for both TCP connections** (`utils.h`: `chiaki_tcp_socket_tune`, `session.c`, `ctrl.c`, test in `test/sock.c`) | The session request and control sockets both get `TCP_NODELAY`, the real-time marking, and `SO_NOSIGPIPE`: a write after the console reset the connection would otherwise raise SIGPIPE, which kills a process that doesn't ignore it (the app ignores it; the `psrp` CLI didn't). The session request socket had none of them. From neo773's fork. |
| **The console's target bitrate** (`streamconnection.c`/`.h`) | `target_bitrate` from the console's connection quality reports was only logged; it's kept now, and the app shows it next to the received rate. In one 33-minute session it sat at the 20 Mbps cap while 7.5 Mbps arrived: the encoder used less than allowed, so the cap wasn't what held the picture back. The protocol's `DEBUG`/`BITRATE` option was tried too: a retail PS5 ignores it (target and received rate unchanged for −8000, +8000 and 0.5), so a bitrate change reconnects. |
| **Each lost frame counted once** (`videoreceiver.c`, test in `test/videoreceiver.c`) | While waiting for a keyframe, every FEC failure counted all frames since the last complete one again, so a few hundred failures reported 169,000 lost frames, and the app's frame numbering (its pacing clock) jumped with them. Now the frames since the last one handed over are counted once, when the next one is. |
| **No deadlock when a PSN registration outlasts the session's wait for it** (`session.c`, test in `test/regist.c`) | The session thread joined the registration thread while holding its state mutex, and the registration's last callback takes that mutex. A stop during the registration (Cancel on PSN pairing, or leaving an internet session while it connects), a console slower than the 10 s wait, or a stop right after the keys arrived left `chiaki_session_join` blocked for good. The mutex is released around the join now, and when the registration fails after a stop, the stop stays the quit reason. |

PR #817 also raised the reorder queue's wait from 16 to 33 ms. That trades latency for fewer lost frames,
so it isn't taken without a measurement. Its other parts (FFmpeg flags, Vulkan, Qt threads) don't apply to
PlayFX.

### What we took from neo773/chiaki-ng

[neo773/chiaki-ng](https://github.com/neo773/chiaki-ng) is another macOS-focused fork (19 commits ahead of
upstream, November 2026). Most of it is chiaki-ng's own Qt app: a Metal renderer, MetalFX, CoreAudio output,
120 Hz. PlayFX has its own versions of those. From the library part:

- **Already here:** the 4 MB receive buffer, the real-time marking, `TCP_NODELAY` on the control connection,
  user-interactive threads.
- **Taken:** the control-request retry, and `SO_NOSIGPIPE` plus the marking on the session request socket
  (the table above).
- **Taken as an idea, in our own code:** decoding off libchiaki's receive thread. See "Asynchronous decoding"
  below.
- **Left out:**
  - its Takion rewrite (2.5 ms reorder timeout, skipping missing packets when FEC can rebuild the frame, a
    256-slot queue, a packet pool, about 400 lines): tuned for wired links. On Wi-Fi it turns late packets
    into lost ones, and it doesn't touch our real problem, the AWDL stall. Its next commit "restores" a few
    things it broke.
  - sending input from the caller's thread instead of waking the sender thread: microseconds, at the cost of
    changing chiaki's locking.
  - a shorter Senkusha ping test: it only applies below 2 ms of round trip (wired); we measure 12–40 ms on
    Wi-Fi.
  - skipping the 10 ms wait before the control connection on PS5: its next commit put a 20 ms wait back.
  - crypto and buffer micro-optimisations: negligible on Apple silicon, and the buffer-clearing change risks
    subtle FEC bugs.

### Asynchronous decoding

Not a chiaki change either. libchiaki calls our video callback on its receive thread, and `VideoDecoder`
used to decode there, synchronously: for the 2–5 ms a frame takes, no packets were read (they waited in the
socket buffer) and no acks went out. VideoToolbox now decodes asynchronously on its own threads
(`kVTDecodeFrame_EnableAsynchronousDecompression`) and the receive thread goes straight back to reading.

- Frames still come out in order, now on VideoToolbox's thread; the renderer already takes them from any
  thread.
- A frame that fails is reported by the next `decode` call, so libchiaki asks for a keyframe one frame later
  than before.
- Before a size change the old session's frames are waited for (they come out first), and stopping a
  session waits for the frames in flight, so none arrive after it stopped.

**Thread priority** isn't a chiaki change: libchiaki calls a hook as each of its threads starts, and our
shim (`psrp.c`, `psrp_thread_qos`) sets the QoS class.

| Threads | QoS class |
|---|---|
| Receive (Takion), resend, decryption keys, controller feedback | `USER_INTERACTIVE` |
| Session, control, congestion, PSN setup | `USER_INITIATED` |
| Everything else | unchanged |

### What it changed

The setup: the PS5 at 1080p60 over Wi-Fi, AWDL on, the app on the 75 Hz monitor, interpolation off, 60 s
each. "Lateness" is how far frames arrive behind the stream clock; each figure is the median of the
2-second p90 readings.

| libchiaki | Lateness | Worst | Lost frames | Shown/s |
|---|---|---|---|---|
| Upstream | 219–555 ms | 323–1941 ms | 2–15 | 49–55 |
| Fork | 79 ms | 194 ms | 0 | 54.4 |
| **Fork + thread priority** | **9.5 ms** | **17–42 ms** | **0** | **56** |

These are one or two runs each, on one network; treat them as direction, not precision.

### Updating

```sh
cd third_party/chiaki-ng
git fetch upstream && git rebase upstream/main     # on branch playfx
git push --force-with-lease origin playfx
cd ../.. && packages/streamcore/scripts/build-chiaki.sh
```

chiaki's own unit tests are off in our build. To run them, configure a separate build with
`-DCHIAKI_ENABLE_TESTS=ON` and build the `chiaki-unit` target; it needs the `test/munit` submodule.

## Network layout

- **Same network.** On the measured setup, the Mac (192.168.50.x) and the PS5 (192.168.0.x) were on
  different subnets behind two routers. That has two costs:
  - **Discovery:** broadcast discovery can't find the console, so only the console IP field on Home
    works.
  - **Delay:** every packet takes about 6 ms more.

  If a second router sits in between, putting it in access-point (bridge) mode removes both.
- **Wire the PS5** if you can. Only the Mac's side is then wireless.
- **5 or 6 GHz** on the Mac, near the access point.

## Measuring

All of these work without the UI:

- **The dev control port** (`PLAYFX_DEV_CONTROL=7780 bun run desktop`, see [dev-control.md](dev-control.md)).
  `GET /status` returns:
  - `stream`: `framesDecoded`, `framesLost`, `rttMs`;
  - `pacing`: `latenessMs` (the p90 lateness behind the stream clock), `delayMs`, `skippedFrames`,
    `clockRestarts`, `wifiStalls` (the periodic stall seen in the frames).

  Sample it every couple of seconds, and compute rates from real timestamps, not from the sampling
  interval.
- **Pings, under load:** `ping -i 0.1 <console IP>` while streaming. Spikes once a second are AWDL.
- **AWDL:** `ifconfig awdl0 | grep status`.

## Known limits

- **The pacing clock follows lateness slowly.** It moved at most 0.5% of a frame per frame, which is what let
  the 219–555 ms figures above build up. When frames are more than half a frame off it now slides by up to 8%
  of a frame per frame, and starts over only when they're a quarter second off (FRAME_INTERPOLATION.md).
- **Steady Wi-Fi depends on AppleScript's administrator prompt and `ifconfig`.** Both exist on every
  macOS release so far, but Apple could restrict them.
- **The fork's fixes are measured on one network.** The reorder-wait change from PR #817 is untested.
- **Not yet tried on a console:** the control-request retry and asynchronous decoding (unit-tested only).
