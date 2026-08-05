// Watchdog for windows on the headset display: other apps' windows and dialogs
// that open there are invisible to the user — every 2 s the sweeper finds them
// and moves them to the monitor (requires the Accessibility permission), or
// warns with an OSD plate.

import AppKit
import ApplicationServices

final class WindowSweeper {
    private let vrFrame: CGRect     // CG coordinates: y down from the top of the main screen
    private let targetFrame: CGRect // where to move windows (the regular monitor)
    private var timer: Timer?
    // Avoid spamming plates every 2 s about the same window
    private var reported: [String: Double] = [:]
    // app name, whether the move succeeded
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
                  // Regular windows and dialogs; the menu bar, Dock and overlays are higher
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

    // Find the process's AX window by matching position and move it to the monitor
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
