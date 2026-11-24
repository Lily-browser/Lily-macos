import AppKit

/// Opt-in (`LILY_SELFTEST_DRAG=1`) part of the self-test that drives the real sidebar with synthesized mouse events:
/// the rows are found through accessibility, then a drag is posted at the HID level, so SwiftUI's List sees a real
/// drag session. It moves the visible window and the pointer for a couple of seconds, so it never runs by default.
@MainActor
enum DragHarness {
    /// The sidebar's list (`NativeTabList`'s table), found by walking the views.
    static func list(in view: NSView) -> NSTableView? {
        if let table = view as? TabListTableView { return table }
        for sub in view.subviews { if let found = list(in: sub) { return found } }
        return nil
    }

    /// The on-screen frame of a list row, in CGEvent's global coordinates (origin top-left).
    static func frame(ofRow row: Int, in table: NSTableView) -> CGRect? {
        guard let window = table.window, row >= 0, row < table.numberOfRows else { return nil }
        let inWindow = table.convert(table.rect(ofRow: row), to: nil)
        return toGlobalTopLeft(window.convertToScreen(inWindow))
    }

    /// Cocoa screen frames have their origin at the bottom left of the primary display; CGEvent's at the top left.
    private static func toGlobalTopLeft(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Posting happens off the main thread: a drag runs its own tracking loop on the main thread, which would
    /// otherwise hold up the very task that is posting the events.
    nonisolated(unsafe) private static var lastPoint = CGPoint.zero
    nonisolated private static func post(_ type: CGEventType, _ point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - lastPoint.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - lastPoint.y))
        event.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseUp ? 0 : 1)
        lastPoint = point
        event.post(tap: .cghidEventTap)
    }

    nonisolated private static func onBackgroundQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { work(); continuation.resume() }
        }
    }

    /// A plain click: proves the synthesized events reach the app at all.
    static func click(_ point: CGPoint) async {
        await onBackgroundQueue {
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                post(type, point)
                Thread.sleep(forTimeInterval: 0.12)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// Press at `start`, move to `end` in small steps, release.
    static func drag(from start: CGPoint, to end: CGPoint) async {
        await onBackgroundQueue {
            post(.mouseMoved, start)
            Thread.sleep(forTimeInterval: 0.15)
            post(.leftMouseDown, start)
            Thread.sleep(forTimeInterval: 0.15)
            let steps = 30
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                Thread.sleep(forTimeInterval: 0.02)
            }
            Thread.sleep(forTimeInterval: 0.25)
            post(.leftMouseUp, end)
        }
    }
}
