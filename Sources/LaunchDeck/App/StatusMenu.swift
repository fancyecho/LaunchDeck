import AppKit

/// Menu bar icon: settings, updates and the one place that really quits.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: LauncherController

    init(controller: LauncherController) {
        self.controller = controller
        super.init()
        item.button?.image = Self.cometGlyph()
        item.button?.toolTip = "LaunchDeck"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt each time it opens so checkmarks and the update entry are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let canvas = controller.canvas

        menu.addItem(ClosureMenuItem(L10n.t("Show LaunchDeck", "显示 LaunchDeck")) { [weak self] in
            self?.controller.show()
        })
        menu.addItem(.separator())

        let pinch = NSMenuItem(title: L10n.t("Pinch Sensitivity", "捏合灵敏度"), action: nil, keyEquivalent: "")
        let pinchMenu = NSMenu()
        for level in Preferences.PinchSensitivity.allCases {
            let option = ClosureMenuItem(level.title) { Preferences.pinchSensitivity = level }
            option.state = Preferences.pinchSensitivity == level ? .on : .off
            pinchMenu.addItem(option)
        }
        pinch.submenu = pinchMenu
        menu.addItem(pinch)

        let comet = ClosureMenuItem(L10n.t("Comet Pointer Trail", "鼠标彗星光效")) { Preferences.cometTrail.toggle() }
        comet.state = Preferences.cometTrail ? .on : .off
        menu.addItem(comet)

        let dock = ClosureMenuItem(L10n.t("Show in Dock", "在程序坞中显示")) { Preferences.showInDock.toggle() }
        dock.state = Preferences.showInDock ? .on : .off
        menu.addItem(dock)

        let login = ClosureMenuItem(L10n.t("Open at Login", "登录时打开")) { LoginItem.toggle() }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(L10n.t("Reset Layout by Category…", "按类别重新整理布局…")) {
            NSApp.activate()
            canvas.confirmResetLayout()
        })
        if !canvas.store.hidden.isEmpty {
            let count = canvas.store.hidden.count
            menu.addItem(ClosureMenuItem(L10n.t("Show \(count) Hidden App(s)", "显示已隐藏的 \(count) 个应用")) {
                canvas.unhideAll()
            })
        }
        menu.addItem(.separator())

        if let release = Updater.shared.available {
            menu.addItem(ClosureMenuItem(L10n.t("Update to \(release.version)…", "更新到 \(release.version)…")) {
                Updater.shared.promptToInstall(release, above: nil)
            })
        } else {
            menu.addItem(ClosureMenuItem(L10n.t("Check for Updates…", "检查更新…")) {
                Updater.shared.checkInteractively(above: nil)
            })
        }
        menu.addItem(ClosureMenuItem(L10n.t("About LaunchDeck", "关于 LaunchDeck")) {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let info = NSMenuItem(title: "LaunchDeck \(version)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let quit = ClosureMenuItem(L10n.t("Quit LaunchDeck", "退出 LaunchDeck")) { AppLifecycle.quit() }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The app icon's comet, as a template image that follows the menu bar's colour.
    private static func cometGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let head = CGPoint(x: 12.4, y: 12.4), r: CGFloat = 3.3
            let tip = CGPoint(x: 2.6, y: 2.6)
            // Tail: tangent to the head, tapering to the tip, fading out along its length.
            let angle = atan2(tip.y - head.y, tip.x - head.x)
            let n = CGPoint(x: -sin(angle), y: cos(angle))
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: head.x + n.x * r * 0.85, y: head.y + n.y * r * 0.85))
            tail.addQuadCurve(to: tip, control: CGPoint(x: 6.2 + n.x * 1.6, y: 6.2 + n.y * 1.6))
            tail.addQuadCurve(to: CGPoint(x: head.x - n.x * r * 0.85, y: head.y - n.y * r * 0.85),
                              control: CGPoint(x: 6.8 - n.x * 0.4, y: 6.8 - n.y * 0.4))
            tail.closeSubpath()
            ctx.saveGState()
            ctx.addPath(tail)
            ctx.clip()
            let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                  colors: [CGColor(gray: 0, alpha: 0.9), CGColor(gray: 0, alpha: 0)] as CFArray,
                                  locations: [0, 1])!
            ctx.drawLinearGradient(fade, start: head, end: tip, options: [])
            ctx.restoreGState()
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2))
            _ = rect
            return true
        }
        image.isTemplate = true
        return image
    }
}
