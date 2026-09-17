# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native 180°/360° video player for a PlayStation VR2 connected to an Apple Silicon Mac through Sony's PC adapter. macOS sees the headset as a plain 4000×2040 display (side-by-side, left half = left eye); head pose comes over USB via libusb (VID 0x054C, PID 0x0CDE). No kexts, no root, no Sony software. Swift + Metal + AVFoundation on top of a small C core.

The repo is published on GitHub: code, comments, UI strings, logs, README and new commit messages are in English (older history is Russian and stays that way).

## Commands

```sh
brew install libusb
cd player && make          # builds psvr2player and wraps it into PSVR2Player.app (ad-hoc codesigned)
cd player && make clean
player/play [video.mp4]    # launch; streams the app log to the terminal
```

- There is no Xcode project, no SwiftPM package, no tests and no linter. `make` is the only check — it must compile cleanly (C is built with `-Wall`).
- Always run through the `.app` bundle via `play`, not the bare `psvr2player` binary. Without `Info.plist` macOS can't show the removable-volume prompt and reads from external disks hang forever; `play` uses `open` so the app, not the terminal, is the "responsible" process for permissions. Rebuilding changes the ad-hoc signature, so granted permissions (Full Disk Access, Accessibility) may need to be re-added.
- The log always goes to `~/Library/Logs/PSVR2Player.log` when stdout is not a terminal (i.e. via `open`/Finder); `play` tails that file. Swift `print` and the C core's `stderr` share one descriptor. Log lines are tagged by subsystem (`[usb]`, `[display]`, …).
- Without a headset display the player falls back to a preview window on the main screen (and without USB it renders with default calibration and no tracking; proximity-sensor logic is disabled there), so the build can be smoke-tested without hardware: `player/play some_180_SBS.mp4`, then check the log. Hot-plugging the *display* is not supported (the player asks for a restart); the USB link reconnects by itself.
- Recon tools in `tools/` have no Makefile; build them one by one (binaries are gitignored):
  ```sh
  clang -O2 -I"$(brew --prefix)/include/libusb-1.0" -L"$(brew --prefix)/lib" -lusb-1.0 tools/psvr2_probe.c -o tools/psvr2_probe
  ```
  They claim USB interfaces exclusively — the player must be closed while they run.
- `swift -O tools/nebula.swift 8192 player/environment.jpg <variant>` regenerates the space environment panorama.
- `tools/tag-hvc1` (in-place 4-byte retag, reversible with `-r`) and `tools/fix-hev1` (ffmpeg remux) fix HEVC files tagged `hev1`, which AVFoundation refuses to decode (log shows `hev1 … decodable: NO`).

## Architecture

Everything lives in `player/`; all Swift files are compiled together as one module with `cpsvr2.h` as the bridging header. A new Swift or C file must be added to the `psvr2player` rule in `player/Makefile` (both the dependency list and the `swiftc` command line).

### C core (`cpsvr2.c`, `lut.c`)

`cpsvr2.c` owns the libusb session. Protocol is ported from Monado's `psvr2` driver; camera/gaze commands come from PSVR2Toolkit (keep `THIRD-PARTY.md` in sync when porting more).

- SLAM thread: bulk EP 0x83, interface 3, ~60 Hz — on-headset fused quaternion + position.
- Status thread: interrupt EP 0x88, interface 7 alt 1 — proximity sensor, Fn button, IPD and IMU batches at 2000 Hz.
- `psvr2_get_predicted_quat()` is what the renderer actually uses: last SLAM pose integrated forward through the IMU ring buffer (SLAM and IMU share the VTS timestamp scale) plus extrapolation by the requested lookahead. Its output is already in Monado-mapped axes; the raw `psvr2_get_pose()` path needs a different component remap (see `HeadTracker.currentOrientation`). Don't "unify" the two mappings.
- A SLAM pose older than 0.5 s counts as invalid in all pose getters (dead stream / unplugged USB); `HeadTracker` then holds the last view and the renderer shows a notice.
- USB reconnect: a read thread that dies on a USB error sets `psvr2_link_lost()`; `AppDelegate.checkUSBLink` (1 s timer, headset-display mode only) runs `psvr2_restart()` until the device is back, then re-reads calibration. After a cable replug the device sometimes comes up with the status interface's alt setting missing (`SetAlternateInterface` → `kIOReturnNotFound`, libusb `ERROR_OTHER`); retrying never cures it, a re-enumeration does — `request_device_reset()` does that on its own thread/context because libusb blocks ~10 s inside `libusb_reset_device`.
- Everything that touches the device handle (`psvr2_restart`, camera start/stop) goes through the serial `psvr2ControlQueue`; only the getters are thread-safe.
- Camera thread (passthrough): interface 6, EP 0x87, `VI` packets carrying two 1024×1016 BC4 planes. It uses its own mutex so it never stalls tracking, the enable command must be sent *after* claiming the interface, and the stream is silenced before the device is closed (use-after-free on exit otherwise). Camera start/stop run on `psvr2ControlQueue` — shutdown blocks (thread join + control transfer) and must not run on the main/render thread; `stopAndWait()` precedes `psvr2_stop()`.
- `lut.c` is the 1024×3 distortion/chromatic LUT from Monado, uploaded once as a Metal buffer.

### Render path (`main.swift`)

One fullscreen-triangle pass. The Metal shader is an inline string (`shaderSource`) compiled at startup, so shader errors surface at launch, not at build time. Per output pixel the fragment shader: undistorts per eye and per color channel (factory calibration + LUT) → builds a view ray → applies per-scanline rolling-shutter correction from the gyro → rotates by the head pose → projects into the video (equirect 360 / half-equirect 180 / fisheye; SBS / top-bottom / mono) → samples YUV and converts to RGB itself → composites the UI panel and virtual cursor, or the passthrough cameras.

- The `Uniforms` struct exists twice — in MSL inside `shaderSource` and in Swift — and the layouts must match exactly. Parameters are packed into generic `p0…p6` vec4 slots; when adding one, update both structs and both sets of slot comments.
- `VideoSource.frameRefs` (pixel buffer + `CVMetalTexture` wrappers) is captured by the command buffer's completion handler: the wrappers must outlive GPU use or the decoder pool may rewrite a frame that is still being sampled.
- Video frames stay in native YUV 4:2:0 (8/10-bit, BT.709/2020, full/video range) via `AVPlayerItemVideoOutput` + `CVMetalTextureCache`. BGRA conversion is unreliable for 8K (gray frame with live audio), so it is only a fallback (`p4.w`).
- `environment.jpg` (shown when no file is open) goes through the same video path as a 360° mono source; the shader works in gamma space, hence `SRGB: false`.
- Frame pacing: the `MTKView` is paused and drawn manually from a `CVDisplayLink` created for the headset's `CGDirectDisplayID`, dispatching `draw()` to main. MTKView's own timer / `CADisplayLink` may tick from a 60 Hz monitor, which shows every frame twice and looks like ghosting. Don't revert to automatic MTKView drawing.
- `Renderer.setPanelRate` derives scanout duration and default pose lookahead (~1.2 frames) from the active 90/120 Hz display mode and re-runs on screen-parameter changes.
- `HeadTracker` composes `offsetCurrent * recenter * q`: recenter removes yaw only (keeps the horizon); the manual scene tilt is pitch-only on purpose (manual yaw + pitch produces roll) with a slerp follower. Long Fn press = full recenter including pitch (for lying down).
- `Renderer.draw` also hosts the per-frame state machines: Fn button (single / double / long press), debounced proximity sensor → auto-pause/resume, mouse capture and first-wear recenter.
- `PlaybackConfig.detect(from:)` guesses projection and stereo layout from the file name.
- Audio is routed to the headset's USB audio output via CoreAudio; input-only PS VR2 audio devices must be skipped (selecting one makes playback never advance). The device has no volume control, so volume is the player's own 0–100 %.

### Windows and input

- The headset window is borderless, above the menu bar, and intentionally never becomes key. Keyboard focus lives in the remote/status window on the regular monitor so system permission dialogs open where the user can see them; keys reach `PlayerView` through a local `NSEvent` monitor.
- `WindowSweeper` (`sweeper.swift`) uses the Accessibility API to move stray windows off the headset display.
- `UIOverlay` (`overlay.swift`) draws the control panel / file picker / Format submenu with CoreGraphics into a 1024×512 texture; the shader places it as a world-anchored quad and draws the virtual cursor. While the headset is worn the real mouse is captured (warped onto the headset screen and disassociated) and only deltas move the virtual cursor; taking the headset off releases it. The cursor-reachable margin constants (`marginU`/`marginV`) are duplicated in the shader. Button presses return `UIAction`s that `PlayerView.perform(uiAction:)` executes — the same path the keyboard uses.
- `meta.swift`: `VideoMetaCache` (background thumbnails/duration/resolution for the picker) and `ResumeStore` (per-file resume position). Persistent state is in `UserDefaults`: `volume`, `lastDir`, `lastFile`, resume positions.

### Known physical limit

Residual motion blur is not a bug: in DisplayPort mode the panel runs full-persistence and no low-persistence command is known.
