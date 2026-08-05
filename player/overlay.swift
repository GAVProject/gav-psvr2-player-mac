// Floating control panel and file picker shown inside the headset.
//
// Appears on mouse movement (while the app is active): the real cursor is
// captured (hidden and frozen over the headset window) and its deltas move a
// virtual cursor over the panel. After 3 s of inactivity the panel hides and
// the mouse is released. The panel is drawn with CoreGraphics into a texture;
// the cursor is drawn in the shader.
//
// File picker mode: scrollable list of folders and video files; opens
// automatically when started without an argument, or via the "File…" button.
//
// Timeline: progress bar with click and drag seeking; on hover it shows the
// time at the cursor position.

import AppKit
import AVFoundation
import Metal

enum UIAction {
    case playPause, seekBack, seekFwd, seekBack30, seekFwd30,
         volDown, volUp, recenter, cycleProjection, cycleStereo
    case seekFraction(Double) // seek to a fraction of the duration (timeline)
}

final class UIOverlay {
    static let texW = 1024
    static let texH = 512

    // Margin around the panel reachable by the cursor (texture fractions; the
    // same values are hard-coded in the shader) — clicking it hides the panel
    static let marginU = 0.05
    static let marginV = 0.10

    private enum PanelMode { case controls, picker, format }

    private enum ButtonAction {
        case ui(UIAction)
        case pickerEntry(Int)
        case pickerUp, pickerDown, pickerCancel, pickerDrives
        case stopVideo // close the file and return to the list
        case timeline
        // "Format" submenu: explicit selection instead of cycling
        case showFormat, formatDone
        case setProjection(Projection), setStereo(StereoLayout), setSpeed(Float)
        case toggleFlip, fovDown, fovUp
        case cycleSpeed
    }

    private struct Button {
        let rect: CGRect // CG texture coordinates (origin bottom-left)
        let label: () -> String
        let action: ButtonAction
        var highlighted = false // currently open file
    }

    private struct PickerEntry {
        let url: URL
        let isDir: Bool
        let name: String
    }

    private(set) var texture: MTLTexture
    private(set) var active = false

    // Virtual cursor in panel texture coordinates: u right, v down, 0..1
    private(set) var cursorU: Double = 0.5
    private(set) var cursorV: Double = 0.5

    // Where to teleport the real cursor on capture (headset screen center, CG coordinates)
    var warpPoint: CGPoint?
    var captureEnabled = true

    weak var renderer: Renderer?
    var onOpenFile: ((URL) -> Void)?
    // true — window on top of everything (normal mode), false — lower it
    // so the system access dialog doesn't end up under our window
    var onWindowLevelRequest: ((Bool) -> Void)?

    private var mode = PanelMode.controls
    private var buttons: [Button] = []
    private var pickerDir = FileManager.default.homeDirectoryForCurrentUser
    private var pickerEntries: [PickerEntry] = []
    private var pickerScroll = 0
    private let pickerRows = 6
    private let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    // Thumbnails and metadata of video files for the list
    private let metaCache = VideoMetaCache()

    // Labels to the left of the "Format" submenu rows
    private var formatLabels: [(text: () -> String, rect: CGRect)] = []

    // Last opened file — highlighted in the list
    private var currentFile: URL?
    // Per-folder scroll position, to come back to the same spot
    private var scrollMemory: [String: Int] = [:]

    // Directory reading runs in the background: on external/network volumes
    // it can block (disk spin-up, macOS access prompt)
    private var loading = false
    private var loadStarted = 0.0
    private var loadToken = 0
    private var mouseCaptured = false
    private var releasedForDialog = false
    // Headset on the head (proximity sensor): headset off means normal work
    // at the Mac — don't touch the mouse and don't wake the panel
    private var hmdWorn = true

    private var lastActivity = CACurrentMediaTime()
    private var lastRedraw = 0.0
    // Motion accumulator for waking the panel: filters out mouse jitter
    private var wakeAccum = 0.0
    private var lastWakeMove = 0.0
    private var lastButtonHeld = 0.0
    private var savedMousePos: CGPoint?
    private var lastHovered: Int = -1

    // Timeline knob dragging: while LMB is held, the cursor position sets
    // the target fraction; the seek itself runs on release
    private var scrubbing = false
    private var scrubFraction = 0.0

    // Popup indicator (e.g. volume): shown even without the panel
    private var osdText: String?
    private var osdUntil = 0.0
    private var osdDirty = false

    private var osdActive: Bool { osdUntil > CACurrentMediaTime() }

    // What the shader should show: the panel and/or the OSD plate
    var displayVisible: Bool { active || osdActive }

    // Remove the plate immediately (entering camera mode — image without UI)
    func clearOSD() {
        osdUntil = 0
        osdText = nil
        osdDirty = true
        redrawSoon()
    }

    func showOSD(_ text: String, duration: Double = 1.5) {
        osdText = text
        osdUntil = CACurrentMediaTime() + duration
        osdDirty = true
        redrawSoon()
    }

    init(device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.texW, height: Self.texH, mipmapped: false)
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)!
        metaCache.onUpdate = { [weak self] in self?.redrawSoon() }
        buildControlButtons()
    }

    // MARK: - Buttons: controls mode

    private func buildControlButtons() {
        let colW = 232.0, rowH = 100.0, gap = 16.0
        let x0 = 24.0
        func rect(_ col: Int, _ row: Int, span: Int = 1) -> CGRect {
            // row 0 — top button row; rows are pinned to the panel bottom,
            // with the timeline above them (CG y grows upward)
            let y = 20.0 + Double(2 - row) * (rowH + gap)
            return CGRect(
                x: x0 + Double(col) * (colW + gap), y: y,
                width: colW * Double(span) + gap * Double(span - 1), height: rowH)
        }

        buttons = [
            Button(rect: CGRect(x: x0, y: 366, width: Double(Self.texW) - 2 * x0, height: 64),
                   label: { "" }, action: .timeline),
            Button(rect: rect(0, 0), label: { "−30 s" }, action: .ui(.seekBack30)),
            Button(rect: rect(1, 0), label: { "−15 s" }, action: .ui(.seekBack)),
            Button(rect: rect(2, 0), label: { "+15 s" }, action: .ui(.seekFwd)),
            Button(rect: rect(3, 0), label: { "+30 s" }, action: .ui(.seekFwd30)),
            Button(rect: rect(0, 1), label: { [weak self] in
                (self?.renderer?.video?.player.rate ?? 0) == 0 ? "▶ Play" : "❚❚ Pause"
            }, action: .ui(.playPause)),
            Button(rect: rect(1, 1), label: { "Vol −" }, action: .ui(.volDown)),
            Button(rect: rect(2, 1), label: { "Vol +" }, action: .ui(.volUp)),
            Button(rect: rect(3, 1), label: { "Recenter" }, action: .ui(.recenter)),
            Button(rect: rect(0, 2), label: { "⏹ Stop" }, action: .stopVideo),
            Button(rect: rect(1, 2, span: 2), label: { [weak self] in
                guard let cfg = self?.renderer?.config else { return "Format…" }
                return "Format: \(cfg.projection.shortLabel) · \(cfg.stereo.shortLabel)"
            }, action: .showFormat),
            Button(rect: rect(3, 2), label: { [weak self] in
                String(format: "%g×", self?.renderer?.playbackRate ?? 1)
            }, action: .cycleSpeed),
        ]
    }

    // MARK: - Buttons: "Format" submenu

    private static let speeds: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

    private func buildFormatButtons() {
        buttons.removeAll()
        formatLabels.removeAll()
        let x0 = 24.0, labelW = 230.0, rowH = 64.0, gap = 16.0
        let optX = x0 + labelW + 16.0
        let optW = Double(Self.texW) - 24.0 - optX

        func rowRect(_ i: Int) -> Double { // CG y of the bottom edge of row i (from the top)
            Double(Self.texH) - 80.0 - Double(i) * (rowH + gap) - rowH
        }
        func addRow(_ i: Int, label: @escaping () -> String,
                    options: [(String, ButtonAction, Bool)]) {
            let y = rowRect(i)
            formatLabels.append((label, CGRect(x: x0, y: y, width: labelW, height: rowH)))
            let g = 12.0
            let w = (optW - Double(options.count - 1) * g) / Double(options.count)
            for (j, opt) in options.enumerated() {
                buttons.append(Button(
                    rect: CGRect(x: optX + Double(j) * (w + g), y: y, width: w, height: rowH),
                    label: { opt.0 }, action: opt.1, highlighted: opt.2))
            }
        }

        let cfg = renderer?.config
        addRow(0, label: { "Projection" }, options: Projection.allCases.map {
            ($0.shortLabel, .setProjection($0), cfg?.projection == $0)
        })
        addRow(1, label: { "Stereo" }, options: StereoLayout.allCases.map {
            ($0.shortLabel, .setStereo($0), cfg?.stereo == $0)
        })
        addRow(2, label: { "Speed" }, options: Self.speeds.map {
            (String(format: "%g×", $0), .setSpeed($0), renderer?.playbackRate == $0)
        })
        addRow(3, label: { [weak self] in
            "Fisheye \(Int(self?.renderer?.config.fisheyeFovDeg ?? 0))°"
        }, options: [
            ("−", .fovDown, false),
            ("+", .fovUp, false),
            (cfg?.flipV ?? 1 < 0 ? "Flip: on" : "Flip: off", .toggleFlip, cfg?.flipV ?? 1 < 0),
        ])

        buttons.append(Button(
            rect: CGRect(x: (Double(Self.texW) - 300) / 2, y: 14, width: 300, height: 56),
            label: { "Done" }, action: .formatDone))
    }

    // MARK: - Buttons: file picker mode

    // File opened from a command-line argument
    func setCurrentFile(_ url: URL) {
        currentFile = url
    }

    func openPicker(startDir: URL? = nil) {
        mode = .picker
        var dir = startDir
        if dir == nil, let current = currentFile {
            dir = current.deletingLastPathComponent()
        }
        if dir == nil, let saved = UserDefaults.standard.string(forKey: "lastFile") {
            currentFile = URL(fileURLWithPath: saved)
        }
        if dir == nil, let saved = UserDefaults.standard.string(forKey: "lastDir") {
            let url = URL(fileURLWithPath: saved)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                dir = url
            }
        }
        if dir == nil {
            let movies = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            dir = FileManager.default.fileExists(atPath: movies.path)
                ? movies : FileManager.default.homeDirectoryForCurrentUser
        }
        loadDir(dir!)
        if !active {
            show()
        }
        redrawSoon()
    }

    private func loadDir(_ dir: URL) {
        // Remember where we stopped in the folder we are leaving
        if !pickerEntries.isEmpty {
            scrollMemory[pickerDir.path] = pickerScroll
        }
        pickerDir = dir
        pickerScroll = 0
        pickerEntries = []
        metaCache.cancelPending() // thumbnails of the folder we left are no longer needed
        loading = true
        loadStarted = CACurrentMediaTime()
        loadToken += 1
        let token = loadToken
        buildPickerButtons()
        redrawSoon()

        let exts = videoExtensions
        DispatchQueue.global(qos: .userInitiated).async {
            var entries: [PickerEntry] = []
            if dir.path == "/" {
                // Above the root — list of mounted drives
                entries.append(PickerEntry(
                    url: URL(fileURLWithPath: "/Volumes"), isDir: true, name: ".."))
            } else if dir.path != "/Volumes" {
                entries.append(PickerEntry(
                    url: dir.deletingLastPathComponent(), isDir: true, name: ".."))
            }

            // Resolve symlinks: /Volumes/Macintosh HD points to /
            let target = dir.resolvingSymlinksInPath()
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: target, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []

            var dirs: [PickerEntry] = []
            var files: [PickerEntry] = []
            for url in contents {
                // fileExists follows symlinks — important for /Volumes/Macintosh HD
                var isDirObjC: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirObjC) else {
                    continue
                }
                if isDirObjC.boolValue {
                    dirs.append(PickerEntry(url: url, isDir: true, name: url.lastPathComponent))
                } else if exts.contains(url.pathExtension.lowercased()) {
                    files.append(PickerEntry(url: url, isDir: false, name: url.lastPathComponent))
                }
            }
            let byName: (PickerEntry, PickerEntry) -> Bool = {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            entries += dirs.sorted(by: byName) + files.sorted(by: byName)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadToken == token else { return }
                self.pickerEntries = entries
                self.loading = false
                self.restoreScroll()
                if self.releasedForDialog {
                    self.releasedForDialog = false
                    self.onWindowLevelRequest?(true)
                    self.captureMouse()
                    self.clearOSD() // dialog answered — remove the hint
                }
                self.buildPickerButtons()
                self.redrawSoon()
            }
        }
    }

    private func buildPickerButtons() {
        buttons.removeAll()
        let x0 = 24.0, gap = 8.0
        let w = Double(Self.texW) - 48.0
        let rowH = 54.0

        for i in 0..<pickerRows {
            let idx = pickerScroll + i
            guard idx < pickerEntries.count else { break }
            let yTop = 76.0 + Double(i) * (rowH + gap)
            let entry = pickerEntries[idx]
            let inVolumes = pickerDir.path == "/Volumes"
            let isCurrent = !entry.isDir && entry.url.path == currentFile?.path
            buttons.append(Button(
                rect: CGRect(x: x0, y: Double(Self.texH) - yTop - rowH, width: w, height: rowH),
                label: {
                    let icon = entry.isDir
                        ? (inVolumes && entry.name != ".." ? "💾 " : "📁 ")
                        : (isCurrent ? "▶ " : "🎬 ")
                    return icon + String(entry.name.prefix(48))
                },
                action: .pickerEntry(idx),
                highlighted: isCurrent))
        }

        let bw = (w - 3 * gap) / 4
        let by = 10.0, bh = 56.0
        let bottom: [(String, ButtonAction)] = [
            ("▲", .pickerUp),
            ("▼", .pickerDown),
            ("💾 Drives", .pickerDrives),
            ("Cancel", .pickerCancel),
        ]
        for (i, item) in bottom.enumerated() {
            buttons.append(Button(
                rect: CGRect(x: x0 + Double(i) * (bw + gap), y: by, width: bw, height: bh),
                label: { item.0 }, action: item.1))
        }
    }

    // Return to the previous position; if the open file is in this folder — to it
    private func restoreScroll() {
        let maxScroll = max(0, pickerEntries.count - pickerRows)

        if let current = currentFile,
           current.deletingLastPathComponent().path == pickerDir.path,
           let idx = pickerEntries.firstIndex(where: { $0.url.path == current.path }) {
            // Put the file in the middle of the visible area
            pickerScroll = min(maxScroll, max(0, idx - pickerRows / 2))
            return
        }

        pickerScroll = min(maxScroll, scrollMemory[pickerDir.path] ?? 0)
    }

    func scrollPicker(rows: Int) {
        guard mode == .picker else { return }
        markActivity()
        pickerScroll = max(0, min(max(0, pickerEntries.count - pickerRows), pickerScroll + rows))
        scrollMemory[pickerDir.path] = pickerScroll
        buildPickerButtons()
        redrawSoon()
    }

    // MARK: - Lifecycle

    // Called every frame from the render loop
    func tick() {
        let (dx, dy) = CGGetLastMouseDelta()
        let moved = dx != 0 || dy != 0
        // While the right button is held, the mouse rotates the scene: don't
        // move the panel cursor and don't show the panel
        let rightHeld = NSEvent.pressedMouseButtons & 0x2 != 0
        // Any mouse button: while pressed and for half a second after,
        // movement doesn't wake the panel — a click always nudges the mouse
        if NSEvent.pressedMouseButtons != 0 {
            lastButtonHeld = CACurrentMediaTime()
        }

        if moved && NSApp.isActive {
            lastActivity = CACurrentMediaTime()
            if active && !rightHeld {
                cursorU = min(1 + Self.marginU, max(-Self.marginU, cursorU + Double(dx) / 900.0))
                cursorV = min(1 + Self.marginV, max(-Self.marginV, cursorV + Double(dy) / 450.0))
            } else if !active && !rightHeld && hmdWorn
                        && renderer?.passthrough?.active != true {
                // In camera mode there is no UI at all: the panel doesn't
                // appear and the mouse isn't captured — you can just look
                // around. A micro-shift from pressing/releasing a button
                // doesn't wake the panel: movement near a press is ignored
                // entirely; otherwise require a noticeable accumulated path
                // without long pauses
                let now = CACurrentMediaTime()
                if now - lastButtonHeld < 0.5 {
                    wakeAccum = 0
                } else {
                    if now - lastWakeMove > 0.3 {
                        wakeAccum = 0
                    }
                    lastWakeMove = now
                    wakeAccum += Double(abs(dx) + abs(dy))
                    if wakeAccum > 15 {
                        show()
                    }
                }
            }
        }

        // Volume read is taking long: macOS showed an access prompt on the
        // monitor. The dialog steals focus from the app, so this check goes
        // before all the NSApp.isActive and panel-visibility exits — otherwise
        // the hint wouldn't show exactly when it is needed
        if loading && !releasedForDialog && CACurrentMediaTime() - loadStarted > 1.5 {
            releasedForDialog = true
            releaseMouse(restorePosition: false)
            // Lower the window: the access dialog could be under it
            onWindowLevelRequest?(false)
            // Stays until the dialog is answered (cleared at the end of loadDir)
            showOSD("Confirm access in the dialog on the main monitor", duration: 3600)
            print("[player] Volume read is taking long — macOS is probably waiting for access permission.")
            print("[player] The dialog should appear on the monitor; if it is not there, click")
            print("[player] \"Open access settings\" in the hint window on the monitor.")
        }

        // Without an open video the hidden panel means an empty gray scene:
        // whoever puts on the headset won't guess to move the mouse, so keep
        // the file list on screen ourselves
        if !active && hmdWorn && NSApp.isActive && renderer?.video == nil
            && renderer?.passthrough?.active != true {
            if mode != .picker {
                openPicker()
            } else {
                show()
            }
        }

        guard active else {
            // Panel hidden, but the OSD plate may have updated — redraw the texture
            if osdDirty {
                osdDirty = false
                redraw()
            }
            return
        }

        // App deactivated — release the mouse
        if !NSApp.isActive {
            hide()
            return
        }

        // While RMB is held, the file picker is open or the timeline is being
        // dragged — auto-hide doesn't tick
        if rightHeld || mode == .picker || scrubbing {
            lastActivity = CACurrentMediaTime()
            if rightHeld {
                return
            }
        }

        if CACurrentMediaTime() - lastActivity > 3.0 {
            hide()
            return
        }

        // Redraw: hover change or progress tick; more often over the timeline
        // so the time plate follows the cursor
        let hovered = hitIndex()
        var maxAge = 0.5
        if scrubbing {
            scrubFraction = timelineFraction()
            maxAge = 1.0 / 30
        } else if hovered >= 0, case .timeline = buttons[hovered].action {
            maxAge = 1.0 / 30
        }
        if hovered != lastHovered || CACurrentMediaTime() - lastRedraw > maxAge {
            redraw()
        }
    }

    // Proximity sensor state change (already debounced in Renderer)
    func setWorn(_ worn: Bool) {
        guard worn != hmdWorn else { return }
        hmdWorn = worn
        if !worn {
            hide() // hides the panel and releases the mouse
        } else if active {
            captureMouse()
        }
    }

    private func captureMouse() {
        guard captureEnabled, hmdWorn, !mouseCaptured else { return }
        mouseCaptured = true
        savedMousePos = CGEvent(source: nil)?.location
        if let warp = warpPoint {
            CGWarpMouseCursorPosition(warp)
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }

    private func releaseMouse(restorePosition: Bool = true) {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        if restorePosition, let pos = savedMousePos {
            CGWarpMouseCursorPosition(pos)
        }
    }

    private func show() {
        active = true
        cursorU = 0.5
        cursorV = 0.5
        renderer?.anchorPanel() // pin the panel in front of the current gaze
        captureMouse()
        redraw()
    }

    func hide() {
        guard active else { return }
        active = false
        releasedForDialog = false
        // The format submenu doesn't survive hiding the panel
        if mode == .format {
            mode = .controls
            buildControlButtons()
        }
        releaseMouse()
    }

    private func cursorCGPoint() -> CGPoint {
        // The cursor is stored with v down; CG texture coordinates have y up
        CGPoint(x: cursorU * Double(Self.texW), y: (1 - cursorV) * Double(Self.texH))
    }

    private func hitIndex() -> Int {
        let p = cursorCGPoint()
        return buttons.firstIndex { $0.rect.contains(p) } ?? -1
    }

    // Click on the panel; returns an action for the player if its button was hit
    func click() -> UIAction? {
        lastActivity = CACurrentMediaTime()
        let idx = hitIndex()
        guard idx >= 0 else {
            // Click outside buttons (or on the margin around the panel) hides
            // the panel. Without an open video keep the file list: behind it
            // is an empty scene
            if renderer?.video != nil || mode != .picker {
                hide()
            }
            return nil
        }

        switch buttons[idx].action {
        case .ui(let action):
            return action
        case .pickerEntry(let i):
            let entry = pickerEntries[i]
            if entry.isDir {
                loadDir(entry.url)
            } else {
                UserDefaults.standard.set(
                    entry.url.deletingLastPathComponent().path, forKey: "lastDir")
                UserDefaults.standard.set(entry.url.path, forKey: "lastFile")
                currentFile = entry.url
                scrollMemory[pickerDir.path] = pickerScroll
                mode = .controls
                buildControlButtons()
                // Don't compete with the decoder of the video being opened
                metaCache.cancelPending()
                onOpenFile?(entry.url)
            }
            redrawSoon()
        case .pickerUp:
            scrollPicker(rows: -pickerRows)
        case .pickerDown:
            scrollPicker(rows: pickerRows)
        case .pickerDrives:
            loadDir(URL(fileURLWithPath: "/Volumes"))
            redrawSoon()
        case .pickerCancel:
            if renderer?.video != nil {
                mode = .controls
                buildControlButtons()
                metaCache.cancelPending()
                redrawSoon()
            }
        case .stopVideo:
            renderer?.stopVideo() // opens the file list itself
        case .showFormat:
            mode = .format
            buildFormatButtons()
            redrawSoon()
        case .formatDone:
            mode = .controls
            buildControlButtons()
            redrawSoon()
        case .setProjection(let p):
            renderer?.config.projection = p
            print("[player] projection: \(p.label)")
            buildFormatButtons()
            redrawSoon()
        case .setStereo(let s):
            renderer?.config.stereo = s
            print("[player] stereo: \(s.label)")
            buildFormatButtons()
            redrawSoon()
        case .setSpeed(let v):
            renderer?.setPlaybackRate(v)
            buildFormatButtons()
            redrawSoon()
        case .toggleFlip:
            renderer?.config.flipV *= -1
            print("[player] vertical flip: \((renderer?.config.flipV ?? 1) < 0 ? "on" : "off")")
            buildFormatButtons()
            redrawSoon()
        case .fovDown:
            renderer?.config.fisheyeFovDeg -= 5
            redrawSoon()
        case .fovUp:
            renderer?.config.fisheyeFovDeg += 5
            redrawSoon()
        case .cycleSpeed:
            let cur = renderer?.playbackRate ?? 1
            let idx = Self.speeds.firstIndex(of: cur) ?? 1
            renderer?.setPlaybackRate(Self.speeds[(idx + 1) % Self.speeds.count])
            redrawSoon()
        case .timeline:
            guard durationSeconds() != nil else { return nil }
            scrubbing = true
            scrubFraction = timelineFraction()
            redrawSoon()
        }
        return nil
    }

    // LMB release: finish timeline dragging
    func mouseUp() -> UIAction? {
        guard scrubbing else { return nil }
        scrubbing = false
        markActivity()
        redrawSoon()
        return .seekFraction(scrubFraction)
    }

    func markActivity() {
        lastActivity = CACurrentMediaTime()
    }

    func redrawSoon() {
        lastRedraw = 0
    }

    // MARK: - Drawing

    private func durationSeconds() -> Double? {
        guard let d = renderer?.video?.player.currentItem?.duration,
              d.isNumeric, d.seconds > 0 else { return nil }
        return d.seconds
    }

    // Fraction of the duration under the cursor (along the timeline track)
    private func timelineFraction() -> Double {
        guard let b = buttons.first(where: { if case .timeline = $0.action { return true }
                                             return false }) else { return 0 }
        let track = trackRect(in: b.rect)
        let x = cursorU * Double(Self.texW)
        return max(0, min(1, (x - track.minX) / track.width))
    }

    private func trackRect(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + 18, y: rect.minY + 12, width: rect.width - 36, height: 12)
    }

    private func timeString(_ t: CMTime) -> String {
        guard t.isNumeric else { return "--:--" }
        let s = Int(t.seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func redraw() {
        lastRedraw = CACurrentMediaTime()
        lastHovered = hitIndex()

        guard let ctx = CGContext(
            data: nil, width: Self.texW, height: Self.texH,
            bitsPerComponent: 8, bytesPerRow: Self.texW * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        ctx.clear(CGRect(x: 0, y: 0, width: Self.texW, height: Self.texH))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        // Panel hidden: draw only the OSD plate on a transparent background
        if !active {
            drawOSDIfNeeded(ctx)
            NSGraphicsContext.restoreGraphicsState()
            upload(ctx)
            return
        }

        let bgRect = CGRect(x: 4, y: 4, width: Self.texW - 8, height: Self.texH - 8)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 0.85))
        ctx.fillPath()

        for (i, b) in buttons.enumerated() {
            let hovered = i == lastHovered
            if case .timeline = b.action {
                drawTimeline(ctx, rect: b.rect, showPreview: hovered || scrubbing)
                continue
            }
            ctx.addPath(CGPath(roundedRect: b.rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
            if hovered {
                ctx.setFillColor(CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 0.95))
            } else if b.highlighted {
                ctx.setFillColor(CGColor(red: 0.24, green: 0.33, blue: 0.52, alpha: 0.95))
            } else {
                ctx.setFillColor(CGColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 0.95))
            }
            ctx.fillPath()
            if case .pickerEntry(let idx) = b.action, !pickerEntries[idx].isDir {
                drawVideoRow(ctx, rect: b.rect, entry: pickerEntries[idx])
                continue
            }
            let fontSize: CGFloat = mode == .picker ? 26 : (mode == .format ? 28 : 34)
            drawText(b.label(), in: b.rect, size: fontSize, color: .white,
                     centered: mode != .picker || !isEntryButton(b))
        }

        // "Format" submenu row labels
        if mode == .format {
            for label in formatLabels {
                drawText(label.text(), in: label.rect, size: 28,
                         color: NSColor(white: 0.8, alpha: 1), centered: false)
            }
        }

        // Header at the top
        let topRect = CGRect(x: 24, y: Double(Self.texH) - 68, width: Double(Self.texW) - 48, height: 48)
        switch mode {
        case .controls:
            if let player = renderer?.video?.player, let item = player.currentItem {
                let progress = "\(timeString(player.currentTime()))  /  \(timeString(item.duration))"
                drawText(progress, in: topRect, size: 36, color: NSColor(white: 0.92, alpha: 1))
            } else {
                drawText("No file open", in: topRect, size: 30, color: NSColor(white: 0.7, alpha: 1))
            }
        case .picker:
            let path = pickerDir.path
            let shown = path.count > 52 ? "…" + path.suffix(51) : path
            drawText(loading ? "Reading… " + shown : shown,
                     in: topRect, size: 26, color: NSColor(white: 0.75, alpha: 1))
        case .format:
            drawText("Playback format", in: topRect, size: 30,
                     color: NSColor(white: 0.92, alpha: 1))
        }

        drawOSDIfNeeded(ctx)

        NSGraphicsContext.restoreGraphicsState()
        upload(ctx)
    }

    private func drawTimeline(_ ctx: CGContext, rect: CGRect, showPreview: Bool) {
        let track = trackRect(in: rect)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(CGColor(red: 0.30, green: 0.32, blue: 0.38, alpha: 0.95))
        ctx.fillPath()

        guard let dur = durationSeconds(), let player = renderer?.video?.player else { return }
        let current = player.currentTime().seconds
        let played = scrubbing
            ? scrubFraction
            : max(0, min(1, (current.isFinite ? current : 0) / dur))

        if played > 0 {
            let fill = CGRect(x: track.minX, y: track.minY,
                              width: track.width * played, height: track.height)
            ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 1))
            ctx.fillPath()
        }

        let knobX = track.minX + track.width * played
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: knobX - 14, y: track.midY - 14, width: 28, height: 28))

        // Time plate at the cursor position (while dragging — at the grab point)
        if showPreview {
            let f = scrubbing ? scrubFraction : timelineFraction()
            let text = timeString(CMTime(seconds: dur * f, preferredTimescale: 600))
            let plateW = 150.0, plateH = 34.0
            let cx = min(max(track.minX + track.width * f, rect.minX + plateW / 2),
                         rect.maxX - plateW / 2)
            let plate = CGRect(x: cx - plateW / 2, y: rect.maxY - plateH,
                               width: plateW, height: plateH)
            ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 0.95))
            ctx.fillPath()
            drawText(text, in: plate, size: 24, color: .white)
        }
    }

    // Video file row in the list: thumbnail, name, duration and resolution,
    // a "where you left off" progress strip over the thumbnail
    private func drawVideoRow(_ ctx: CGContext, rect: CGRect, entry: PickerEntry) {
        metaCache.request(entry.url)
        let meta = metaCache.meta(for: entry.url)

        let thumbRect = CGRect(x: rect.minX + 5, y: rect.minY + 4,
                               width: 82, height: rect.height - 8)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: thumbRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        if let thumb = meta?.thumb {
            ctx.draw(thumb, in: thumbRect)
        } else {
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fill(thumbRect)
            drawText("🎬", in: thumbRect, size: 22, color: .white)
        }
        if let pos = ResumeStore.position(for: entry.url),
           let d = meta?.durationS, d > 0 {
            let frac = max(0, min(1, pos / d))
            ctx.setFillColor(CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 1))
            ctx.fill(CGRect(x: thumbRect.minX, y: thumbRect.minY,
                            width: thumbRect.width * frac, height: 4))
        }
        ctx.restoreGState()

        let textX = rect.minX + 100
        let isCurrent = entry.url.path == currentFile?.path
        let name = (isCurrent ? "▶ " : "") + String(entry.name.prefix(52))
        drawText(name,
                 in: CGRect(x: textX, y: rect.midY - 2,
                            width: rect.maxX - 8 - textX, height: rect.height / 2 - 2),
                 size: 23, color: .white, centered: false)

        var info: [String] = []
        if let d = meta?.durationS, d.isFinite, d > 0 {
            info.append(timeString(CMTime(seconds: d, preferredTimescale: 600)))
        }
        if let dims = meta?.dims, dims.width > 0 {
            info.append("\(Int(dims.width))×\(Int(dims.height))")
        }
        if !info.isEmpty {
            drawText(info.joined(separator: " · "),
                     in: CGRect(x: textX, y: rect.minY + 2,
                                width: rect.maxX - 8 - textX, height: rect.height / 2 - 4),
                     size: 18, color: NSColor(white: 0.62, alpha: 1), centered: false)
        }
    }

    private func drawOSDIfNeeded(_ ctx: CGContext) {
        guard osdActive, let text = osdText else { return }
        // The plate adapts to the text; very long text gets a smaller font
        var fontSize = 34.0
        var textW = Double(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).size().width)
        let maxTextW = Double(Self.texW) - 88
        if textW > maxTextW {
            fontSize *= maxTextW / textW
            textW = maxTextW
        }
        let w = max(440.0, textW + 48), h = 72.0
        let rect = CGRect(x: (Double(Self.texW) - w) / 2, y: Double(Self.texH) - h - 14, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 0.9))
        ctx.fillPath()
        drawText(text, in: rect, size: fontSize, color: .white)
    }

    private func upload(_ ctx: CGContext) {
        if let data = ctx.data {
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.texW, Self.texH), mipmapLevel: 0,
                withBytes: data, bytesPerRow: Self.texW * 4)
        }
    }

    private func isEntryButton(_ b: Button) -> Bool {
        if case .pickerEntry = b.action { return true }
        return false
    }

    private func drawText(_ s: String, in rect: CGRect, size: CGFloat, color: NSColor,
                          centered: Bool = true) {
        let str = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
        ])
        let sz = str.size()
        let x = centered ? rect.midX - sz.width / 2 : rect.minX + 18
        str.draw(at: CGPoint(x: x, y: rect.midY - sz.height / 2))
    }
}
