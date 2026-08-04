// Плавающая панель управления и выбора файла в шлеме.
//
// Появляется при движении мыши (когда приложение активно): реальный курсор
// захватывается (прячется и замораживается над окном шлема), его дельты двигают
// виртуальный курсор по панели. Через 3 с бездействия панель скрывается и мышь
// освобождается. Панель рисуется CoreGraphics в текстуру, курсор — в шейдере.
//
// Режим выбора файла: список папок и видеофайлов с прокруткой; открывается
// автоматически при старте без аргумента или кнопкой «Файл…».

import AppKit
import AVFoundation
import Metal

enum UIAction {
    case playPause, seekBack, seekFwd, seekBack30, seekFwd30,
         volDown, volUp, recenter, cycleProjection, cycleStereo
}

final class UIOverlay {
    static let texW = 1024
    static let texH = 512

    private enum PanelMode { case controls, picker }

    private enum ButtonAction {
        case ui(UIAction)
        case pickerEntry(Int)
        case pickerUp, pickerDown, pickerCancel
        case showPicker
    }

    private struct Button {
        let rect: CGRect // CG-координаты текстуры (origin слева внизу)
        let label: () -> String
        let action: ButtonAction
    }

    private struct PickerEntry {
        let url: URL
        let isDir: Bool
        let name: String
    }

    private(set) var texture: MTLTexture
    private(set) var active = false

    // Виртуальный курсор в координатах текстуры панели: u вправо, v вниз, 0..1
    private(set) var cursorU: Double = 0.5
    private(set) var cursorV: Double = 0.5

    // Куда телепортировать реальный курсор при захвате (центр экрана шлема, CG-координаты)
    var warpPoint: CGPoint?
    var captureEnabled = true

    weak var renderer: Renderer?
    var onOpenFile: ((URL) -> Void)?

    private var mode = PanelMode.controls
    private var buttons: [Button] = []
    private var pickerDir = FileManager.default.homeDirectoryForCurrentUser
    private var pickerEntries: [PickerEntry] = []
    private var pickerScroll = 0
    private let pickerRows = 6
    private let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    private var lastActivity = CACurrentMediaTime()
    private var lastRedraw = 0.0
    private var savedMousePos: CGPoint?
    private var lastHovered: Int = -1

    // Всплывающий индикатор (например, громкость): показывается и без панели
    private var osdText: String?
    private var osdUntil = 0.0
    private var osdDirty = false

    private var osdActive: Bool { osdUntil > CACurrentMediaTime() }

    // Что показывать в шейдере: панель и/или плашку OSD
    var displayVisible: Bool { active || osdActive }

    func showOSD(_ text: String) {
        osdText = text
        osdUntil = CACurrentMediaTime() + 1.5
        osdDirty = true
        redrawSoon()
    }

    init(device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.texW, height: Self.texH, mipmapped: false)
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)!
        buildControlButtons()
    }

    // MARK: - Кнопки: режим управления

    private func buildControlButtons() {
        let colW = 232.0, rowH = 104.0, gap = 16.0
        let x0 = 24.0
        func rect(_ col: Int, _ row: Int, span: Int = 1) -> CGRect {
            // row 0 — верхний ряд кнопок; в CG-координатах y растёт вверх
            let y = Double(Self.texH) - 96.0 - Double(row + 1) * (rowH + gap) + gap
            return CGRect(
                x: x0 + Double(col) * (colW + gap), y: y,
                width: colW * Double(span) + gap * Double(span - 1), height: rowH)
        }

        buttons = [
            Button(rect: rect(0, 0), label: { "−30 с" }, action: .ui(.seekBack30)),
            Button(rect: rect(1, 0), label: { "−15 с" }, action: .ui(.seekBack)),
            Button(rect: rect(2, 0), label: { "+15 с" }, action: .ui(.seekFwd)),
            Button(rect: rect(3, 0), label: { "+30 с" }, action: .ui(.seekFwd30)),
            Button(rect: rect(0, 1), label: { [weak self] in
                (self?.renderer?.video?.player.rate ?? 0) == 0 ? "▶ Играть" : "❚❚ Пауза"
            }, action: .ui(.playPause)),
            Button(rect: rect(1, 1), label: { "Тише" }, action: .ui(.volDown)),
            Button(rect: rect(2, 1), label: { "Громче" }, action: .ui(.volUp)),
            Button(rect: rect(3, 1), label: { "Рецентр" }, action: .ui(.recenter)),
            Button(rect: rect(0, 2), label: { "Файл…" }, action: .showPicker),
            Button(rect: rect(1, 2, span: 2), label: { [weak self] in
                "Проекция: " + (self?.renderer?.config.projection.shortLabel ?? "")
            }, action: .ui(.cycleProjection)),
            Button(rect: rect(3, 2), label: { [weak self] in
                self?.renderer?.config.stereo.shortLabel ?? ""
            }, action: .ui(.cycleStereo)),
        ]
    }

    // MARK: - Кнопки: режим выбора файла

    func openPicker(startDir: URL? = nil) {
        mode = .picker
        var dir = startDir
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
        pickerDir = dir
        pickerScroll = 0
        pickerEntries = []

        if dir.path != "/" {
            pickerEntries.append(PickerEntry(url: dir.deletingLastPathComponent(), isDir: true, name: ".."))
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var dirs: [PickerEntry] = []
        var files: [PickerEntry] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                dirs.append(PickerEntry(url: url, isDir: true, name: url.lastPathComponent))
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                files.append(PickerEntry(url: url, isDir: false, name: url.lastPathComponent))
            }
        }
        let byName: (PickerEntry, PickerEntry) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        pickerEntries += dirs.sorted(by: byName) + files.sorted(by: byName)

        buildPickerButtons()
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
            buttons.append(Button(
                rect: CGRect(x: x0, y: Double(Self.texH) - yTop - rowH, width: w, height: rowH),
                label: { (entry.isDir ? "📁 " : "🎬 ") + String(entry.name.prefix(48)) },
                action: .pickerEntry(idx)))
        }

        let bw = (w - 2 * gap) / 3
        let by = 10.0, bh = 56.0
        buttons.append(Button(
            rect: CGRect(x: x0, y: by, width: bw, height: bh),
            label: { "▲" }, action: .pickerUp))
        buttons.append(Button(
            rect: CGRect(x: x0 + bw + gap, y: by, width: bw, height: bh),
            label: { "▼" }, action: .pickerDown))
        buttons.append(Button(
            rect: CGRect(x: x0 + 2 * (bw + gap), y: by, width: bw, height: bh),
            label: { "Отмена" }, action: .pickerCancel))
    }

    func scrollPicker(rows: Int) {
        guard mode == .picker else { return }
        markActivity()
        pickerScroll = max(0, min(max(0, pickerEntries.count - pickerRows), pickerScroll + rows))
        buildPickerButtons()
        redrawSoon()
    }

    // MARK: - Жизненный цикл

    // Вызывается каждый кадр из цикла рендера
    func tick() {
        let (dx, dy) = CGGetLastMouseDelta()
        let moved = dx != 0 || dy != 0
        // Пока зажата правая кнопка, мышь крутит сцену: курсор панели не
        // двигаем и панель не показываем
        let rightHeld = NSEvent.pressedMouseButtons & 0x2 != 0

        if moved && NSApp.isActive {
            lastActivity = CACurrentMediaTime()
            if active && !rightHeld {
                cursorU = min(1, max(0, cursorU + Double(dx) / 900.0))
                cursorV = min(1, max(0, cursorV + Double(dy) / 450.0))
            } else if !active && !rightHeld {
                show()
            }
        }

        guard active else {
            // Панель скрыта, но плашка OSD могла обновиться — перерисуем текстуру
            if osdDirty {
                osdDirty = false
                redraw()
            }
            return
        }

        // Свернули приложение — освобождаем мышь
        if !NSApp.isActive {
            hide()
            return
        }

        // Пока зажата ПКМ или открыт выбор файла — автоскрытие не тикает
        if rightHeld || mode == .picker {
            lastActivity = CACurrentMediaTime()
            if rightHeld {
                return
            }
        }

        if CACurrentMediaTime() - lastActivity > 3.0 {
            hide()
            return
        }

        // Перерисовка: смена ховера или тик прогресса
        let hovered = hitIndex()
        if hovered != lastHovered || CACurrentMediaTime() - lastRedraw > 0.5 {
            redraw()
        }
    }

    private func show() {
        active = true
        cursorU = 0.5
        cursorV = 0.5
        if captureEnabled {
            savedMousePos = CGEvent(source: nil)?.location
            if let warp = warpPoint {
                CGWarpMouseCursorPosition(warp)
            }
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        }
        redraw()
    }

    func hide() {
        guard active else { return }
        active = false
        if captureEnabled {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            if let pos = savedMousePos {
                CGWarpMouseCursorPosition(pos)
            }
        }
    }

    private func cursorCGPoint() -> CGPoint {
        // Курсор хранится с v вниз, CG-координаты текстуры — y вверх
        CGPoint(x: cursorU * Double(Self.texW), y: (1 - cursorV) * Double(Self.texH))
    }

    private func hitIndex() -> Int {
        let p = cursorCGPoint()
        return buttons.firstIndex { $0.rect.contains(p) } ?? -1
    }

    // Клик по панели; возвращает действие для плеера, если попали в его кнопку
    func click() -> UIAction? {
        lastActivity = CACurrentMediaTime()
        let idx = hitIndex()
        guard idx >= 0 else {
            // Клик мимо кнопок в режиме управления — скрыть панель
            if mode == .controls {
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
                mode = .controls
                buildControlButtons()
                onOpenFile?(entry.url)
            }
            redrawSoon()
        case .pickerUp:
            scrollPicker(rows: -pickerRows)
        case .pickerDown:
            scrollPicker(rows: pickerRows)
        case .pickerCancel:
            if renderer?.video != nil {
                mode = .controls
                buildControlButtons()
                redrawSoon()
            }
        case .showPicker:
            openPicker()
        }
        return nil
    }

    func markActivity() {
        lastActivity = CACurrentMediaTime()
    }

    func redrawSoon() {
        lastRedraw = 0
    }

    // MARK: - Отрисовка

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

        // Панель скрыта: рисуем только плашку OSD на прозрачном фоне
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
            ctx.addPath(CGPath(roundedRect: b.rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.setFillColor(hovered
                ? CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 0.95)
                : CGColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 0.95))
            ctx.fillPath()
            let fontSize: CGFloat = mode == .picker ? 26 : 34
            drawText(b.label(), in: b.rect, size: fontSize, color: .white,
                     centered: mode != .picker || !isEntryButton(b))
        }

        // Заголовок сверху
        let topRect = CGRect(x: 24, y: Double(Self.texH) - 68, width: Double(Self.texW) - 48, height: 48)
        switch mode {
        case .controls:
            if let player = renderer?.video?.player, let item = player.currentItem {
                let progress = "\(timeString(player.currentTime()))  /  \(timeString(item.duration))"
                drawText(progress, in: topRect, size: 36, color: NSColor(white: 0.92, alpha: 1))
            } else {
                drawText("Файл не открыт", in: topRect, size: 30, color: NSColor(white: 0.7, alpha: 1))
            }
        case .picker:
            let path = pickerDir.path
            let shown = path.count > 52 ? "…" + path.suffix(51) : path
            drawText(shown, in: topRect, size: 26, color: NSColor(white: 0.75, alpha: 1))
        }

        drawOSDIfNeeded(ctx)

        NSGraphicsContext.restoreGraphicsState()
        upload(ctx)
    }

    private func drawOSDIfNeeded(_ ctx: CGContext) {
        guard osdActive, let text = osdText else { return }
        let w = 440.0, h = 72.0
        let rect = CGRect(x: (Double(Self.texW) - w) / 2, y: Double(Self.texH) - h - 14, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 0.9))
        ctx.fillPath()
        drawText(text, in: rect, size: 34, color: .white)
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
