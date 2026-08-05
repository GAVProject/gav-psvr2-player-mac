// Сторож окон на дисплее шлема: чужие окна и диалоги, открывшиеся на нём,
// пользователю не видны — сторож раз в 2 с находит их и переносит на монитор
// (нужно разрешение «Универсальный доступ»), либо предупреждает плашкой.

import AppKit
import ApplicationServices

final class WindowSweeper {
    private let vrFrame: CGRect     // CG-координаты: y вниз от верха главного экрана
    private let targetFrame: CGRect // куда переносить (обычный монитор)
    private var timer: Timer?
    // Чтобы не сыпать плашками каждые 2 с об одном и том же окне
    private var reported: [String: Double] = [:]
    // имя приложения, удалось ли перенести
    var onStray: ((String, Bool) -> Void)?

    init(vrFrame: CGRect, targetFrame: CGRect) {
        self.vrFrame = vrFrame
        self.targetFrame = targetFrame
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sweep()
        }
    }

    private func sweep() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  // Обычные окна и диалоги; строка меню, Dock и оверлеи — выше
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer <= 8,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                              width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard rect.width > 60, rect.height > 40,
                  vrFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }

            let name = (info[kCGWindowOwnerName as String] as? String) ?? "?"
            let moved = AXIsProcessTrusted() ? move(pid: pid, rect: rect) : false

            let key = "\(pid)-\(Int(rect.minX))-\(Int(rect.minY))"
            let now = CACurrentMediaTime()
            if moved || (reported[key] ?? -1e9) + 30 < now {
                reported[key] = now
                onStray?(name, moved)
            }
        }
    }

    // Найти AX-окно процесса по совпадению позиции и передвинуть на монитор
    private func move(pid: pid_t, rect: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            == .success, let windows = value as? [AXUIElement] else { return false }

        for win in windows {
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
                == .success, let posRef else { continue }
            var pos = CGPoint.zero
            guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
                  abs(pos.x - rect.minX) < 3, abs(pos.y - rect.minY) < 3 else { continue }

            var target = CGPoint(
                x: min(max(targetFrame.minX, targetFrame.midX - rect.width / 2),
                       targetFrame.maxX - rect.width),
                y: min(max(targetFrame.minY + 40, targetFrame.midY - rect.height / 2),
                       targetFrame.maxY - rect.height))
            guard let tv = AXValueCreate(.cgPoint, &target) else { continue }
            if AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, tv)
                == .success {
                return true
            }
        }
        return false
    }
}
