import AppKit

/// User settings, stored in UserDefaults and changed from the menu bar icon.
enum Preferences {
    enum PinchSensitivity: String, CaseIterable {
        case low, medium, high

        var title: String {
            switch self {
            case .low: L10n.t("Low", "较低")
            case .medium: L10n.t("Medium", "适中")
            case .high: L10n.t("High", "较高")
            }
        }

        /// Finger spread ratios: where the reveal starts and where it completes,
        /// for pinching in (open) and spreading out (close).
        var thresholds: (openStart: CGFloat, openEnd: CGFloat, closeStart: CGFloat, closeEnd: CGFloat) {
            switch self {
            case .low: (0.85, 0.55, 1.15, 1.6)
            case .medium: (0.88, 0.6, 1.12, 1.5)
            case .high: (0.91, 0.66, 1.08, 1.4)
            }
        }
    }

    private static let defaults = UserDefaults.standard

    static var pinchSensitivity: PinchSensitivity {
        get { defaults.string(forKey: "pinchSensitivity").flatMap(PinchSensitivity.init) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "pinchSensitivity") }
    }

    /// The comet that follows the pointer over empty space.
    static var cometTrail: Bool {
        get { defaults.object(forKey: "cometTrail") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cometTrail") }
    }

    static var showInDock: Bool {
        get { defaults.object(forKey: "showInDock") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "showInDock")
            applyDockVisibility()
        }
    }

    /// Dock icon or menu bar only. The launcher, pinch and menu bar icon keep
    /// working either way.
    static func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}

/// Quitting for real (from the menu bar, for an update, or at logout). Any other
/// quit request, such as Quit in the Dock or ⌘Q, just sends LaunchDeck to the
/// menu bar, where it keeps running.
enum AppLifecycle {
    private(set) static var reallyQuitting = false

    static func quit() {
        reallyQuitting = true
        NSApp.terminate(nil)
    }

    /// True while the system is logging out, restarting or shutting down.
    static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(0x7768_793F))  // 'why?'
        else { return false }
        return reason.enumCodeValue != 0
    }
}
