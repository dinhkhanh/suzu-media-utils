import AppKit
import SwiftUI

extension View {
    /// Plain-key shortcuts for the window this view is in (culling keys, Quick Look…). They're seen before the
    /// focused control (so a list's type-to-select doesn't eat digits), but never while typing in a text field, with
    /// ⌘, ⌃ or ⌥ held, or when a sheet or another window is in front. Return true when the key was used.
    func onWindowKeys(_ handler: @escaping (NSEvent) -> Bool) -> some View {
        background(KeyCatcher(handler: handler))
    }
}

private struct KeyCatcher: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.handler = handler
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.handler = handler }

    final class CatcherView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                      !(window.firstResponder is NSText),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      self.handler?(event) == true
                else { return event }
                return nil
            }
        }
    }
}

/// Key codes the culling and browsing keys use.
enum KeyCode {
    static let returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53, space: UInt16 = 49
    static let left: UInt16 = 123, right: UInt16 = 124, home: UInt16 = 115, end: UInt16 = 119
}
