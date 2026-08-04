// Плавающая панель управления в шлеме.
//
// Появляется при движении мыши (когда приложение активно): реальный курсор
// захватывается (прячется и замораживается над окном шлема), его дельты двигают
// виртуальный курсор по панели. Через 3 с бездействия панель скрывается и мышь
// освобождается. Панель рисуется CoreGraphics в текстуру, курсор — в шейдере.

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

    private(set) var texture: MTLTexture
    private(set) var active = false

    // Виртуальный курсор в координатах текстуры панели: u вправо, v вниз, 0..1
    private(set) var cursorU: Double = 0.5
    private(set) var cursorV: Double = 0.5

    // Куда телепортировать реальный курсор при захвате (центр экрана шлема, CG-координаты)
    var warpPoint: CGPoint?
    var captureEnabled = true

    weak var renderer: Renderer?

    private var lastActivity = CACurrentMediaTime()
    private var lastRedraw = 0.0
    private var savedMousePos: CGPoint?
    private var lastHovered: Int = -1

    private struct Button {
        let rect: CGRect // CG-координаты текстуры (origin слева внизу)
        let label: () -> String
        let action: UIAction
    }

    private var buttons: [Button] = []

    init(device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.texW, height: Self.texH, mipmapped: false)
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)!
        buildButtons()
    }

    private func buildButtons() {
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
            Button(rect: rect(0, 0), label: { "−30 с" }, action: .seekBack30),
            Button(rect: rect(1, 0), label: { "−15 с" }, action: .seekBack),
            Button(rect: rect(2, 0), label: { "+15 с" }, action: .seekFwd),
            Button(rect: rect(3, 0), label: { "+30 с" }, action: .seekFwd30),
            Button(rect: rect(0, 1), label: { [weak self] in
                (self?.renderer?.video?.player.rate ?? 0) == 0 ? "▶ Играть" : "❚❚ Пауза"
            }, action: .playPause),
            Button(rect: rect(1, 1), label: { "Тише" }, action: .volDown),
            Button(rect: rect(2, 1), label: { "Громче" }, action: .volUp),
            Button(rect: rect(3, 1), label: { "Рецентр" }, action: .recenter),
            Button(rect: rect(0, 2, span: 2), label: { [weak self] in
                "Проекция: " + (self?.renderer?.config.projection.shortLabel ?? "")
            }, action: .cycleProjection),
            Button(rect: rect(2, 2, span: 2), label: { [weak self] in
                "Стерео: " + (self?.renderer?.config.stereo.label ?? "")
            }, action: .cycleStereo),
        ]
    }

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

        guard active else { return }

        // Пока зажата ПКМ, панель скрыта визуально, но захват мыши держим
        // и таймер автоскрытия не тикает
        if rightHeld {
            lastActivity = CACurrentMediaTime()
            return
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

    // Клик по панели; возвращает действие, если попали в кнопку
    func click() -> UIAction? {
        lastActivity = CACurrentMediaTime()
        let idx = hitIndex()
        guard idx >= 0 else { return nil }
        return buttons[idx].action
    }

    func markActivity() {
        lastActivity = CACurrentMediaTime()
    }

    func redrawSoon() {
        lastRedraw = 0
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

        let bgRect = CGRect(x: 4, y: 4, width: Self.texW - 8, height: Self.texH - 8)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 0.85))
        ctx.fillPath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        for (i, b) in buttons.enumerated() {
            let hovered = i == lastHovered
            ctx.addPath(CGPath(roundedRect: b.rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.setFillColor(hovered
                ? CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 0.95)
                : CGColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 0.95))
            ctx.fillPath()
            drawText(b.label(), in: b.rect, size: 34, color: .white)
        }

        // Строка прогресса сверху
        if let player = renderer?.video?.player, let item = player.currentItem {
            let progress = "\(timeString(player.currentTime()))  /  \(timeString(item.duration))"
            let topRect = CGRect(x: 0, y: Double(Self.texH) - 92, width: Double(Self.texW), height: 64)
            drawText(progress, in: topRect, size: 38, color: NSColor(white: 0.92, alpha: 1))
        }

        NSGraphicsContext.restoreGraphicsState()

        if let data = ctx.data {
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.texW, Self.texH), mipmapLevel: 0,
                withBytes: data, bytesPerRow: Self.texW * 4)
        }
    }

    private func drawText(_ s: String, in rect: CGRect, size: CGFloat, color: NSColor) {
        let str = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
        ])
        let sz = str.size()
        str.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }
}
