# S2725QC Control

Native macOS volume and brightness control for the **Dell S2725QC** over DDC/CI, without
Dell Display and Peripheral Manager (DDPM).

- **Stock volume works.** The Control Center sound slider, the volume keys and the native
  volume HUD all control the monitor's speakers.
- **2% volume steps** on the volume keys (macOS normally uses 1/16).
- **Brightness keys** control whichever monitor the pointer is on, with the native
  brightness HUD (1/16 steps, 1/64 with Shift+Option).
- **Multiple monitors as quad speakers.** With two monitors side by side, the virtual device is a
  4-speaker (quadraphonic) output: each monitor's inner speaker is front left/right and its outer
  speaker rear left/right. Stereo content plays on all four. One volume control drives both
  monitors, and brightness is per monitor.
- **Menu bar sliders** for each monitor's brightness and the shared volume.
- **No microphone indicator.** Audio is handed over through shared memory, not a loopback input.
- Changes go to the monitor immediately on a dedicated thread; only the newest value is written,
  so holding a key or dragging a slider never lags.

Tested on an M5 Pro MacBook Pro, macOS 26.5, with one and two S2725QCs over USB-C.

## Why this exists

macOS exposes the S2725QC's speakers as a DisplayPort audio device with no volume control,
so the stock slider is greyed out. Dell's DDPM works around that by watching the volume keys,
which is laggy and doesn't help the Control Center slider.

## How it works

```
 apps ──► "DELL S2725QC (DDC)"  virtual quad output device (driver/), L R Ls Rs
            │  volume / mute controls ─────────► agent ──► DDC/CI VCP 0x62 ──► monitor volume
            │  mixed audio
            ▼
         POSIX shared-memory ring ──► agent ─┬─► left monitor:  outer speaker Ls, inner speaker L
                                             └─► right monitor: inner speaker R,  outer speaker Rs
```

### Multiple monitors

Identical monitors share a model name, so the agent ties each monitor's parts together by
hardware identity, not by name:

- **DDC ⇄ screen:** the EDID serial read over `IOAVService` matches `CGDisplaySerialNumber`.
- **DDC ⇄ audio:** the DDC service and the `DCPAVAudioDriver` sit under the same display
  coprocessor port (`dispextN`) in the IORegistry; the driver's `device UID` is the CoreAudio UID.

Monitors are then ordered by their left edge in System Settings → Displays → Arrange, and the
pair acts as quad speakers, assuming each monitor is angled toward you:

```
        [L]                        [R]
  [Ls]   LEFT MONITOR    (Mac)    RIGHT MONITOR   [Rs]
   outer    inner                   inner    outer
```

Most apps play stereo, and macOS sends stereo only to the front pair. While the rear channels are
silent, the outer speakers copy the front channel of their side, so stereo fills all four
speakers. When rear audio appears (surround content), the outer speakers crossfade to it over
100 ms and keep playing the rear channels until they have been silent for 10 s. A single monitor
plays L+Ls on its left speaker and R+Rs on its right.

### Timing and speaker calibration

The driver publishes its clock (sample time ↔ host time) in the shared ring. For every output
buffer, each monitor's reader plays exactly the sample that belongs to the moment that buffer
reaches the monitor, a fixed 2048 frames (43 ms) late. Both monitors therefore play every sample
at the same instant, sample-accurately and independent of when playback started, and a slow
rate correction (max ±0.2%, inaudible) follows each monitor's clock drift. The fixed 43 ms is
reported to apps as device latency, so video players compensate for it.

On top of that, **S2725QC Speaker Setup** lines the four speakers up at your seat. Open it from
the menu bar icon (**Speaker Setup…**) or from `~/Applications/S2725QC Control/`. It's a normal
window app that runs only while it's open.

- **Room layout:** a top-down view with you at the bottom. Drag each monitor into place and turn
  it with its round handle (or click **Face me**). It shows every speaker's distance to you.
- **Test:** plays a tone on just that speaker.
- **Sync from layout:** delays nearer speakers so all four arrive with the farthest one, computed
  from the drawn distances (sound travels 34.3 cm per ms). No microphone needed.
- **Calibrate with microphone:** plays a short sweep on each speaker at 25% volume, hears it with
  the Mac's built-in microphone, applies per-speaker delays, then measures again to verify and
  shows before → after. Keep the Mac where it usually sits (its microphone stands in for your
  ears) and the room quiet. Microphone access is requested once and used only while measuring.
  On the reference setup: 0–1.7 ms apart before, within 0.02 ms after.

The delays are stored in the agent's preferences and take effect immediately.

Each monitor has its own reader, so their clocks are tracked independently.
Plugging, unplugging or rearranging displays rebuilds this automatically.

| Part | What it does |
|---|---|
| `driver/` | AudioServerPlugIn built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.2 (git submodule). Output-only, with real volume/mute controls, so macOS enables the stock slider and keys. `shm_writer.c` publishes the mixed output into a shared-memory ring instead of a loopback input. |
| `Sources/ShmRing/` | Ring layout (quad audio plus the driver's clock) and the real-time reader, which plays each sample at its scheduled time on every monitor, applies per-speaker calibration delays, and handles the rear-speaker fallback. |
| `Sources/Setup/` | **S2725QC Speaker Setup** (SwiftUI): room layout, per-speaker test tones, and layout- or microphone-based speaker sync. |
| `Sources/Agent/` | Background agent: discovers monitors (`Monitors.swift`), plays the ring to each one while something is playing, mirrors the slider to every monitor's DDC volume, handles volume/brightness keys (`CGEventTap`) with the native HUD (`OSD.framework`), and puts a slider menu in the menu bar. If macOS selects the monitor's raw output, it reroutes to the virtual device; if the monitor is unplugged, it falls back to the built-in speakers. |
| `Sources/Launcher/` | A small, stable app that loads the agent library from next to itself. Rebuilding the agent doesn't change the app's signature, so its Accessibility permission survives rebuilds. |
| `Sources/Shared/DDC.swift` | DDC/CI over `IOAVService` (Apple Silicon). |
| `Sources/CLI/` | `ddc` command-line tool. |

### Why not the stock brightness slider?

Control Center enables its brightness slider only for displays that macOS's DisplayServices says
it can drive (built-in and Apple displays). There's no driver interface for a third party to
provide brightness for another monitor, so brightness uses the keys and the menu bar instead.

## Requirements

- Apple Silicon Mac. DDC goes through `IOAVService`; Intel Macs aren't supported.
- macOS 14 or later. Developed on macOS 26.
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.
- DDC/CI enabled in the monitor's OSD menu.
- Quit or uninstall Dell DDPM; it fights over the same keys and DDC bus.

## Build

```sh
git clone --recursive https://github.com/aadhi1014/s2725qc-control.git
cd s2725qc-control
./build.sh
```

Output in `build/`: `S2725QC Control.app` (launcher), `libS2725QCAgent.dylib` (agent),
`S2725QC Setup.app` (speaker setup), `ddc` (CLI). The driver is built to `driver/build/S2725QC.driver`.
Run `./build.sh --launcher` to rebuild the launcher app too (that resets its Accessibility grant).

## Install

**1. Driver** (admin). Copy from a location outside Desktop/Documents/Downloads, because
privacy protection blocks root from reading those folders when using the GUI prompt:

```sh
cp -R driver/build/S2725QC.driver /tmp/
osascript -e 'do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/S2725QC.driver && cp -R /tmp/S2725QC.driver /Library/Audio/Plug-Ins/HAL/ && chown -R root:wheel /Library/Audio/Plug-Ins/HAL/S2725QC.driver && killall coreaudiod" with administrator privileges'
```

"DELL S2725QC (DDC)" then appears under System Settings → Sound → Output.

**2. Agent at login.** The repo must stay where it is; the agent loads from `build/`.

```sh
sed "s|__APP__|$PWD/build/S2725QC Control.app|" LaunchAgent/dev.solderable.s2725qc-control.plist \
  > ~/Library/LaunchAgents/dev.solderable.s2725qc-control.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.solderable.s2725qc-control.plist
```

**3. Accessibility.** Allow **S2725QC Control** in System Settings → Privacy & Security →
Accessibility, which is needed for the volume and brightness keys. The agent picks it up within a few seconds.

Logs: `/tmp/s2725qc-control.log`.

## `ddc` CLI

```sh
build/ddc list                  # 0: dispext0 serial …  (0 = leftmost)
build/ddc get brightness        # 100/100  (leftmost monitor)
build/ddc -d 1 set brightness 60
build/ddc get volume
build/ddc set volume 20
```

Controls: `brightness` (0x10), `contrast` (0x12), `volume` (0x62), `mute` (0x8D).
`-d N` picks a monitor by position, 0 being the leftmost.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/dev.solderable.s2725qc-control
rm ~/Library/LaunchAgents/dev.solderable.s2725qc-control.plist
osascript -e 'do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/S2725QC.driver && killall coreaudiod" with administrator privileges'
```

## Other monitors

Built and tested only for the S2725QC. The model string is matched in
`Sources/Agent/Agent.swift` (`monitorModel`) and the device name is set in `driver/build.sh`.
Other DDC/CI monitors with DisplayPort/USB-C audio will probably work after changing those.

## Caveats

- Uses private macOS APIs: `IOAVService` (DDC), `OSDManager` (HUD) and DisplayServices.
  A macOS update could break them.
- Adds a fixed 43 ms of audio latency (reported to apps, so video stays in sync). The monitors'
  own audio processing adds more that no app can see; on the S2725QC the full path from app to
  ear measured about 124 ms.
- Changing volume with the monitor's own buttons isn't reflected back on the Mac.
- With two or more monitors, all of them follow one volume level. When the agent starts,
  it brings every monitor to the leftmost monitor's level.
- Mute is applied in the driver (silence), not sent to the monitor.

## License

GPL-3.0, because the driver is built from BlackHole (GPL-3.0). See [LICENSE](LICENSE).
