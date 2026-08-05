# GAV PSVR2 Player for macOS

![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-blue)
![Swift](https://img.shields.io/badge/Swift%20%2B%20Metal-orange?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
[![Donate](https://img.shields.io/badge/donate-DonationAlerts-ff6b35)](https://www.donationalerts.com/r/andreygav90)

Native 180°/360° video player for a PlayStation VR2 connected to a Mac
(Apple Silicon) through Sony's official PC adapter (CFI-ZAA1). No kexts, no
Sony software: macOS sees the headset as a regular 4000×2040@120 display,
and head pose is read over USB via libusb.

Tested on: MacBook Air M4, macOS 15+, PSVR2 + PC adapter (DP cable + USB).

The adapter is mandatory. Plugging the headset cable straight into a Mac
Thunderbolt port doesn't even power it up (no standby LED, nothing appears
on USB) — the Mac port supplies at most 15 W, the headset needs more, and the
power comes from the adapter's brick. No software can work around that.

## Features

- Side-by-side stereo rendering with lens-distortion and chromatic-aberration
  correction using the factory calibration of your specific headset (protocol
  from the [Monado](https://gitlab.freedesktop.org/monado/monado) driver,
  BSL-1.0)
- Head tracking: the headset's on-board SLAM (~60 Hz) plus IMU integration
  (2000 Hz) with extrapolation — honest 120 fps with no ghosting
- Per-scanline rolling-shutter compensation driven by the gyro
- Projections: equirect 360°, half-equirect 180°, fisheye (adjustable FOV);
  SBS / top-bottom / mono stereo; auto-detected from the file name
- Hardware video decoding (AVFoundation) — 8K HEVC is not a problem;
  playback speed 0.5–2× with pitch-corrected audio
- Audio routes to the headset's headphones automatically. Recenter with the
  Fn button — the small button on the underside of the visor, bottom right
  when the headset is on your head
- Control panel and file picker rendered inside the headset (appears on
  mouse move, anchored in space); timeline with click and drag seeking
- File list with thumbnails, duration and resolution; the player remembers
  where you stopped in every file and resumes from there
- A "Format" submenu for explicit projection / stereo layout / speed /
  fisheye-FOV selection
- Stop button closes the file and returns to the picker; when no file is
  open the picker stays on screen, floating in a black space environment
  with a nebula and stars (procedurally generated, pure-black background —
  OLED-friendly; regenerate your own with `tools/nebula.swift`)
- Proximity-sensor integration: video auto-pauses when you take the headset
  off and resumes when you put it back on; the mouse is captured only while
  the headset is worn — take it off and your Mac is usable as usual, no
  alt-tabbing; on the first wear after launch the scene and panel recenter
  to your gaze
- Passthrough: view from the headset's front cameras (double-press Fn
  or `B`) to look around without removing the headset; video pauses and the
  player UI hides. The cameras sit wider than your eyes, so converge the
  images with `,`/`.`; `M` toggles stereo/mono, `+`/`-` sets the lens angle
- A remote/status window on the monitor: shows current state and hotkeys,
  keeps keyboard focus so macOS permission prompts never open invisibly on
  the headset display; its close button quits the player. If a permission
  dialog does appear, the headset shows a hint and releases the mouse so you
  can click it. Stray windows that land on the headset display are moved
  back to the monitor automatically (needs the Accessibility permission,
  otherwise the player warns you)

## Screenshots

What the headset display receives — the raw SBS frame with lens-distortion
and chromatic correction; the control panel is anchored in space over the
video:

![In-headset control panel](docs/headset-panel.jpg)

The file picker floating in the space environment (procedurally generated,
pure-black background for the OLED panels):

![In-headset file picker](docs/headset-picker.jpg)

The remote/status window on the monitor:

<img src="docs/remote.png" width="550" alt="Remote window">

## Building

```sh
brew install libusb
cd player && make      # builds PSVR2Player.app
```

## Running

```sh
player/play        # or ./play from the player/ directory
```

This is the normal way to use the player: it starts with the file picker
right in the headset — browse folders (thumbnails, durations, resume
positions) and click a video with the virtual cursor. You can also launch
`player/PSVR2Player.app` from Finder/Dock instead.

To open a specific file right away, pass it as an argument:

```sh
player/play "video_180_SBS.mp4"
```

`play` keeps the log in your terminal; when launched from Finder/Dock the
log goes to `~/Library/Logs/PSVR2Player.log` (watch with `tail -f` or
Console.app).

In macOS Settings, set the "PS VR2" display to 120 Hz.

Keys: `Space` pause · `R`/Fn button on the headset — recenter (long-press Fn
centers the video on your gaze, handy when lying down; double-press — camera
view) · `B` camera view (`M` stereo/mono, `,`/`.` convergence) ·
`F` projection · `G` stereo · `V` vertical flip · `←/→` ±15 s · `↑/↓` volume ·
`+/-` fisheye FOV or camera lens angle · `Q` quit.
Mouse: move — panel · click — select · right-drag — tilt scene ·
wheel — scroll list. Trackpad: two-finger scroll — list, two-finger
press-drag — tilt scene.
Debug: `P` pose prediction · `[`/`]` look-ahead · `S` scanline correction ·
`C` chromatic correction · `D` vsync.

## Layout

- `player/` — the player itself: `main.swift` (AppKit + Metal +
  AVFoundation + the shader), `overlay.swift` (in-headset panel and file
  picker), `meta.swift` (thumbnail/metadata cache), `sweeper.swift` (moves
  stray windows off the headset display), `passthrough.swift` (camera frames
  to BC4 textures), `cpsvr2.c` (SLAM/IMU/status/camera streams over libusb),
  `lut.c` (distortion table from Monado), `environment.jpg` (the space
  panorama shown when nothing is playing)
- `tools/nebula.swift` — generator of the space environment
  (`swift -O tools/nebula.swift 8192 player/environment.jpg <variant>`)
- `tools/fix-hev1`, `tools/tag-hvc1` — fix HEVC files tagged `hev1`, which
  AVFoundation refuses to decode: `tag-hvc1` retags the 4 bytes in place when
  the codec parameters are already in the track header; `fix-hev1` remuxes
  via ffmpeg when they are not
- `tools/psvr2_probe.c` — USB protocol diagnostics

## License and acknowledgements

MIT — see [LICENSE](LICENSE).

The PSVR2 protocol was reverse-engineered by the Monado driver authors
(Jan Schmidt, Joel Valenciano, Beyley Cardellio and others); distortion
formulas and protocol are ported from [Monado](https://gitlab.freedesktop.org/monado/monado)
(BSL-1.0). Eye-tracking protocol and camera commands come from
[PSVR2Toolkit](https://github.com/BnuuySolutions/PSVR2Toolkit) (MIT).
Full third-party license texts: [THIRD-PARTY.md](THIRD-PARTY.md).

## ☕ Support

If this player made your day, you can support development:

- [DonationAlerts](https://www.donationalerts.com/r/andreygav90) — card / SBP
- Crypto:

| Coin | Network | Address |
|------|---------|---------|
| BTC | Bitcoin | `bc1qmzh0mzrev4mx7aww57w5akt72c8gcxnsw96t9g` |
| ETH — also USDT/USDC (ERC-20) and L2 (Arbitrum, Base) | Ethereum | `0xf036DE380BC42BabF07D89E69F7345824d20ea79` |
| USDT (TRC-20) — also TRX | Tron | `TFNHZmXZu7CyMevFDmNWzJ8gdUXsXX3TWY` |

## What else the headset can do (exploration)

Through the PC adapter the headset exposes more than the player uses.
Recon tools (`tools/`, require the player to be closed — the interfaces are
claimed exclusively):

- `psvr2_scan` — map of all USB interfaces and endpoints with live
  sniffing; shows where active streams exist
- `psvr2_gaze` — eye tracking: the `GS` stream (interface 5, EP 0x85) is
  enabled by vendor command `0x0C`. **Works**: packets flow and the
  structure matches byte for byte (0x148). But the validity fields stay
  zero — a per-user calibration blob is needed (that part of PSVR2Toolkit
  is closed)
- `psvr2_camera` — passthrough (already built into the player). The cameras
  are enabled by vendor command `0x0B` (payload `01 00 00 00 10 00 00 00`),
  frames arrive on interface 6, EP 0x87 with a `VI` signature: a 256-byte
  header plus two 1024×1016 BC4 textures (left and right cameras, 8-bit
  grayscale, wide angle). Important: send the command **after** claiming
  the interface, otherwise the stream stays silent

Also visible in the streams: `LD` (interface 8) — 508×508 eye cameras,
60 Hz; `ST` (interface 11) — ~23 MB/s of SLAM telemetry; `RP` (interface
9) — periodic ~800 KB dumps.
