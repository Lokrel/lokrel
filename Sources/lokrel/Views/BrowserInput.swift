import AppKit
import SwiftUI

struct PreviewKeyboardInput: NSViewRepresentable {
    var key: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.key = key }

    final class KeyView: NSView {
        var key: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                return self.key?(event) == true ? nil : event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct CardFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// Observe mouse-down without delaying or consuming the native drag and context-menu events.
struct BrowserInput: NSViewRepresentable {
    var frames: [String: CGRect]
    var click: (String, NSEvent) -> Void
    var key: (NSEvent) -> Bool
    var drag: (String) -> ModelDragContent?
    var handlesSelection = true

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.frames = frames
        view.click = click
        view.key = key
        view.drag = drag
        view.handlesSelection = handlesSelection
    }

    final class InputView: NSView, NSDraggingSource {
        var frames: [String: CGRect] = [:]
        var click: ((String, NSEvent) -> Void)?
        var key: ((NSEvent) -> Bool)?
        var drag: ((String) -> ModelDragContent?)?
        var handlesSelection = true
        private var monitor: Any?
        private var mouseDownID: String?
        private var didDrag = false
        private var mouseDownPoint = NSPoint.zero
        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if event.type == .leftMouseDragged {
                    guard !self.didDrag, let id = self.mouseDownID,
                          hypot(point.x - self.mouseDownPoint.x, point.y - self.mouseDownPoint.y) > 5,
                          let content = self.drag?(id) else { return event }
                    self.didDrag = true
                    let items = content.pasteboardItems().enumerated().map { index, writer in
                        let item = NSDraggingItem(pasteboardWriter: writer)
                        let icon = NSImage(systemSymbolName: content.requiresFileChoice ? "tag" : "doc", accessibilityDescription: nil)
                        item.setDraggingFrame(NSRect(x: point.x + CGFloat(index * 5), y: point.y, width: 48, height: 48), contents: icon)
                        return item
                    }
                    if !items.isEmpty { self.beginDraggingSession(with: items, event: event, source: self) }
                    self.mouseDownID = nil
                    return nil
                }
                if event.type == .leftMouseUp {
                    defer { self.mouseDownID = nil }
                    if !self.didDrag, let id = self.mouseDownID, self.frames[id]?.contains(point) == true { self.click?(id, event) }
                    return event
                }
                self.mouseDownID = nil
                self.didDrag = false
                guard self.bounds.contains(point), let id = self.frames.filter({ $0.value.contains(point) })
                    .min(by: { $0.value.width * $0.value.height < $1.value.width * $1.value.height })?.key else { return event }
                self.mouseDownID = id
                self.mouseDownPoint = point
                if self.handlesSelection { self.window?.makeFirstResponder(self) }
                self.click?(id, event)
#if DEBUG
                if CommandLine.arguments.contains("--ui-test-library") {
                    let milliseconds = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
                    print("Selection state updated in \(String(format: "%.1f", milliseconds)) ms")
                    fflush(stdout)
                }
#endif
                return event
            }
        }
        override func keyDown(with event: NSEvent) {
            if key?(event) != true { super.keyDown(with: event) }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
