import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LauncherController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        controller = LauncherController()

        // Thumb and three fingers pinched together open the launcher; spread apart closes it.
        PinchMonitor.shared.handler = { [weak self] event in
            self?.controller.handlePinch(event)
        }
        PinchMonitor.shared.start()
        Updater.shared.start()

        // Opened by the user: show right away. Started at login: stay out of the way
        // until the first pinch or Dock click.
        let atLogin = Self.launchedAtLogin
        controller.reload { [weak self] in
            if !atLogin { self?.controller.show() }
        }
    }

    private static var launchedAtLogin: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Login items registered through SMAppService don't always carry that flag;
        // a launch within the first minutes after boot with the item enabled counts.
        return SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 240
    }

    /// Clicking the Dock icon toggles the launcher, like the old Launchpad tile.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.toggle()
        return false
    }

    @objc private func showLauncher(_ sender: Any?) {
        controller.show()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkInteractively(above: nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)

        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t("About LaunchDeck", "关于 LaunchDeck"),
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: L10n.t("Show LaunchDeck", "显示 LaunchDeck"),
                                action: #selector(showLauncher(_:)), keyEquivalent: "")
        show.target = self
        let update = menu.addItem(withTitle: L10n.t("Check for Updates…", "检查更新…"),
                                  action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        update.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("Hide LaunchDeck", "隐藏 LaunchDeck"),
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: L10n.t("Quit LaunchDeck", "退出 LaunchDeck"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu

        // Standard editing commands, so ⌘C / ⌘V / ⌘A work while renaming a folder.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L10n.t("Edit", "编辑"))
        edit.addItem(withTitle: L10n.t("Undo", "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L10n.t("Redo", "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.t("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.t("Copy", "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.t("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.t("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}
