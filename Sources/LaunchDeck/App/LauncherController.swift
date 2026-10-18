import AppKit
import SwiftUI

/// Owns the launcher window and drives showing, hiding and launching.
final class LauncherController {
    let chrome = ChromeState()
    let canvas: LauncherCanvas
    private let catalog = AppCatalog()
    private let window = LauncherWindow()
    private let container = NSView()
    private let fallbackBlur = NSVisualEffectView()
    private let searchHost: PassiveHostingView<SearchBarContainer>
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var hideWork: DispatchWorkItem?
    private var lastScan = Date.distantPast
    private var wallpaperKey: String?
    private(set) var isVisible = false

    private enum PinchPhase { case idle, opening, closing, finished }
    private var pinchPhase = PinchPhase.idle
    private var pinchProgress: CGFloat = 0

    init() {
        canvas = LauncherCanvas(chrome: chrome)
        searchHost = PassiveHostingView(rootView: SearchBarContainer(state: chrome))
        searchHost.sizingOptions = []

        container.wantsLayer = true
        fallbackBlur.material = .fullScreenUI
        fallbackBlur.blendingMode = .behindWindow
        fallbackBlur.state = .active
        fallbackBlur.alphaValue = 0
        for v in [fallbackBlur, canvas] as [NSView] {
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
        }
        container.addSubview(searchHost)
        window.contentView = container

        canvas.dismissHandler = { [weak self] in self?.hide() }
        canvas.launchHandler = { [weak self] app in self?.launch(app) }
        canvas.metricsChanged = { [weak self] m in self?.placeSearchBar(m) }

        installEventMonitors()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hide()
        })
        if let screen = NSScreen.main { loadWallpaper(for: screen) }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func reload(completion: (() -> Void)? = nil) {
        lastScan = Date()
        catalog.scan { [weak self] items in
            self?.canvas.setApps(items)
            completion?()
        }
    }

    /// `interactive` puts the window up fully transparent for a pinch to reveal.
    func show(interactive: Bool = false) {
        guard !isVisible else { return }
        isVisible = true
        hideWork?.cancel()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(screen.frame, display: false)
        container.frame = CGRect(origin: .zero, size: screen.frame.size)
        canvas.frame = container.bounds
        fallbackBlur.frame = container.bounds
        loadWallpaper(for: screen)
        canvas.ensureBackdropFallback()
        canvas.prepareForShow(topInset: screen.safeAreaInsets.top, interactive: interactive)
        placeSearchBar(canvas.metrics)

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)

        if !canvas.hasWallpaper {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; fallbackBlur.animator().alphaValue = 1 }
        }
        if !interactive {
            // Let the window put up its collapsed state once before animating in.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible else { return }
                self.canvas.animateIn()
            }
        }

        if Date().timeIntervalSince(lastScan) > 3 { reload() }
        #if DEBUG
        DebugSnapshot.runIfRequested(window: window, canvas: canvas)
        #endif
    }

    func hide(launching key: String? = nil) {
        guard isVisible else { return }
        isVisible = false
        canvas.animateOut(launching: key)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; fallbackBlur.animator().alphaValue = 0 }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            self.window.orderOut(nil)
            self.canvas.resetAfterHide()
            // Hand focus back to whatever was frontmost before we appeared.
            if key == nil, NSApp.isActive { NSApp.hide(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
    }

    // MARK: - Pinch

    /// Thumb and three fingers pinching in reveal the launcher as they move; spreading
    /// them dismisses it the same way. Releasing past the halfway-ish point completes
    /// the gesture, otherwise it springs back.
    func handlePinch(_ event: PinchMonitor.Event) {
        switch event {
        case .began:
            pinchPhase = .idle
        case .changed(let ratio, let travel):
            pinchChanged(ratio, travel: travel)
        case .ended:
            switch pinchPhase {
            case .opening:
                if pinchProgress >= Self.commitProgress { canvas.finishPresentation(open: true) } else { hide() }
            case .closing:
                if pinchProgress >= Self.commitProgress { hide() } else { canvas.finishPresentation(open: true) }
            default:
                break
            }
            pinchPhase = .idle
        }
    }

    // Pinch tuning. The reveal starts once the fingers have closed in by ~12% and is
    // complete at ~40%; letting go commits only past half of that range.
    private static let openStart: CGFloat = 0.88
    private static let openEnd: CGFloat = 0.6
    private static let closeStart: CGFloat = 1.12
    private static let closeEnd: CGFloat = 1.5
    private static let commitProgress: CGFloat = 0.5

    private func pinchChanged(_ ratio: CGFloat, travel: CGFloat) {
        if pinchPhase == .idle {
            // Fingers sliding together without changing spread: a swipe, not a pinch.
            if travel > 0.07, abs(1 - ratio) < 0.06 {
                pinchPhase = .finished
                return
            }
            if !isVisible, ratio < Self.openStart {
                pinchPhase = .opening
                show(interactive: true)
            } else if isVisible, canvas.isShown, ratio > Self.closeStart {
                pinchPhase = .closing
            } else {
                return
            }
        }
        switch pinchPhase {
        case .opening:
            pinchProgress = min(max((Self.openStart - ratio) / (Self.openStart - Self.openEnd), 0), 1)
            canvas.setPresentation(easeOut(pinchProgress))
            if pinchProgress >= 1 {
                canvas.finishPresentation(open: true)
                pinchPhase = .finished
            }
        case .closing:
            pinchProgress = min(max((ratio - Self.closeStart) / (Self.closeEnd - Self.closeStart), 0), 1)
            canvas.setPresentation(1 - easeOut(pinchProgress))
            if pinchProgress >= 1 {
                hide()
                pinchPhase = .finished
            }
        default:
            break
        }
    }

    private func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 2) }

    private func launch(_ app: AppItem) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error { NSLog("LaunchDeck: failed to open \(app.url.path): \(error)") }
        }
        hide(launching: app.key)
    }

    private func placeSearchBar(_ m: GridMetrics) {
        let size = CGSize(width: 380, height: 48)
        // The container isn't flipped, so measure from the bottom.
        let y = container.bounds.height - m.searchBarY - size.height / 2
        searchHost.frame = CGRect(x: (container.bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
    }

    private func loadWallpaper(for screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen).flatMap(Self.resolveWallpaper) else {
            wallpaperKey = nil
            canvas.setWallpaper(nil)
            return
        }
        let px = CGSize(width: (screen.frame.width * 0.5).rounded(), height: (screen.frame.height * 0.5).rounded())
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(px.width)x\(px.height)|\(stamp?.timeIntervalSince1970 ?? 0)"
        guard key != wallpaperKey else { return }
        wallpaperKey = key
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = WallpaperRenderer.render(url: url, pixelSize: px)
            DispatchQueue.main.async {
                guard let self, self.wallpaperKey == key else { return }
                self.canvas.setWallpaper(image)
            }
        }
    }

    /// Live-wallpaper apps (e.g. Mirage) rotate their image files, so the reported
    /// URL can point at a file that no longer exists. Fall back to the newest image
    /// in the same folder.
    private static func resolveWallpaper(_ url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { return url }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        let imageTypes: Set<String> = ["heic", "jpg", "jpeg", "png", "tiff", "tif", "webp"]
        let candidates = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { imageTypes.contains($0.pathExtension.lowercased()) } ?? []
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    private func installEventMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, !self.canvas.isEditingText else { return event }
            return self.canvas.handleKey(event) ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.canvas.handleScroll(event)
            return nil
        } as Any)
    }
}
