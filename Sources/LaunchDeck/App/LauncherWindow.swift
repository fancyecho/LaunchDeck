import AppKit

/// Borderless, transparent window that covers the whole screen, menu bar included,
/// on whichever Space is active when it opens (also over full-screen apps).
final class LauncherWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        // Moves to the active Space each time it's ordered in, rather than joining
        // all Spaces: the window server's all-Spaces membership can go stale (the
        // window ended up on every Space but Desktop 1), and then the launcher
        // opened on another desktop or not at all.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
