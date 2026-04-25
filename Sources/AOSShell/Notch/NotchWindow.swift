import AppKit

// MARK: - NotchWindow
//
// Per notch-dev-guide.md §3.1. Subclassed NSWindow tuned for a transparent,
// always-on-top, all-Spaces overlay window. Required attributes:
//   - level above status bar so it sits over the menu bar
//   - collectionBehavior covers full-screen apps + Spaces switching
//   - canBecomeKey/Main = true so the prompt TextField receives keystrokes

final class NotchWindow: NSWindow {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        configureForNotchOverlay()
    }

    private func configureForNotchOverlay() {
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        hasShadow = false
        ignoresMouseEvents = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
