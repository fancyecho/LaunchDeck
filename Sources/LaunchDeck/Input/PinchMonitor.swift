import AppKit
import os

/// Raw trackpad touch record from the private MultitouchSupport framework.
/// Layout must match the C struct exactly (96 bytes).
struct MTPoint { var x: Float; var y: Float }
struct MTVector { var position: MTPoint; var velocity: MTPoint }
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

/// Streams the classic Launchpad gesture system-wide: thumb and three fingers
/// pinching together or spreading apart. Reads raw touches from MultitouchSupport
/// because AppKit never delivers four-finger pinches to apps.
final class PinchMonitor {
    /// `changed` carries how spread the fingers are relative to when they landed
    /// (below 1 pinching in, above 1 spreading out) and how far their centre has
    /// travelled, which tells a pinch apart from a four-finger swipe.
    enum Event { case began, changed(ratio: CGFloat, travel: CGFloat), ended }

    static let shared = PinchMonitor()

    var handler: ((Event) -> Void)?

    private typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private var createList: CreateListFn?
    private var register: RegisterFn?
    private var unregister: RegisterFn?
    private var startDevice: StartFn?
    private var stopDevice: StopFn?

    private var deviceList: CFMutableArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var wakeObserver: NSObjectProtocol?
    private var hotplugTimer: Timer?

    private static let log = Logger(subsystem: "io.github.launchdeck", category: "pinch")
    private static var lock = os_unfair_lock()
    private static var trackers: [UnsafeMutableRawPointer: PinchTracker] = [:]

    private init() {
        guard MemoryLayout<MTTouch>.stride == 96 else {
            Self.log.error("Unexpected MTTouch layout: \(MemoryLayout<MTTouch>.stride)")
            return
        }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            Self.log.error("MultitouchSupport unavailable")
            return
        }
        func sym<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        createList = sym("MTDeviceCreateList", as: CreateListFn.self)
        register = sym("MTRegisterContactFrameCallback", as: RegisterFn.self)
        unregister = sym("MTUnregisterContactFrameCallback", as: RegisterFn.self)
        startDevice = sym("MTDeviceStart", as: StartFn.self)
        stopDevice = sym("MTDeviceStop", as: StopFn.self)
    }

    var isAvailable: Bool { createList != nil && register != nil && startDevice != nil }

    func start() {
        guard isAvailable else { return }
        attachDevices()
        // Device handles go stale across sleep; reattach on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.restart() }
        }
        // Pick up a Magic Trackpad connected (or reconnected) after launch.
        hotplugTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, let createList = self.createList,
                  let list = createList()?.takeRetainedValue() else { return }
            if CFArrayGetCount(list) != self.devices.count { self.restart() }
        }
    }

    func restart() {
        detachDevices()
        attachDevices()
    }

    private func attachDevices() {
        guard let createList, let register, let startDevice,
              let list = createList()?.takeRetainedValue() else { return }
        deviceList = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, PinchMonitor.contactCallback)
            startDevice(device, 0)
            devices.append(device)
        }
        Self.log.info("Watching \(self.devices.count) multitouch device(s)")
    }

    private func detachDevices() {
        for device in devices {
            unregister?(device, PinchMonitor.contactCallback)
            stopDevice?(device)
        }
        devices.removeAll()
        deviceList = nil
        os_unfair_lock_lock(&Self.lock)
        Self.trackers.removeAll()
        os_unfair_lock_unlock(&Self.lock)
    }

    /// Runs on MultitouchSupport's own thread for every touch frame.
    private static let contactCallback: ContactCallback = { device, touches, count, _, _ in
        guard let device else { return 0 }
        var points: [(Float, Float)] = []
        if let touches, count > 0 {
            points.reserveCapacity(Int(count))
            let stride = MemoryLayout<MTTouch>.stride
            for i in 0..<Int(count) {
                let t = touches.load(fromByteOffset: i * stride, as: MTTouch.self)
                // 3 = making contact, 4 = touching.
                if t.state == 3 || t.state == 4 {
                    points.append((t.normalized.position.x, t.normalized.position.y))
                }
            }
        }

        os_unfair_lock_lock(&lock)
        var tracker = trackers[device] ?? PinchTracker()
        let events = tracker.update(points)
        trackers[device] = tracker
        os_unfair_lock_unlock(&lock)

        if !events.isEmpty {
            DispatchQueue.main.async {
                for e in events { PinchMonitor.shared.handler?(e) }
            }
        }
        return 0
    }
}

/// Compares how spread out four or more fingers are now against when they landed.
struct PinchTracker {
    private var active = false
    private var baseline: Float = 0
    private var fingerCount = 0
    private var lastRatio: Float = 1
    private var smoothed: Float = 1
    private var startCenter: (Float, Float) = (0, 0)

    /// Trackpads are wider than tall; scale x so distances are roughly physical.
    private static let aspect: Float = 1.55

    mutating func update(_ points: [(Float, Float)]) -> [PinchMonitor.Event] {
        let n = points.count
        if n < 3 {
            defer { active = false; fingerCount = 0 }
            return active ? [.ended] : []
        }
        guard n >= 4 else { return [] }  // a finger briefly lifting keeps the gesture alive

        let cx = points.reduce(0) { $0 + $1.0 } / Float(n)
        let cy = points.reduce(0) { $0 + $1.1 } / Float(n)
        let spread = points.reduce(0) { acc, p in
            let dx = (p.0 - cx) * Self.aspect
            let dy = p.1 - cy
            return acc + (dx * dx + dy * dy).squareRoot()
        } / Float(n)
        guard spread > 0.005 else { return [] }

        if !active {
            active = true
            fingerCount = n
            baseline = spread
            lastRatio = 1
            smoothed = 1
            startCenter = (cx, cy)
            return [.began]
        }
        if n != fingerCount {
            // A finger joined or left: rebase so the ratio doesn't jump.
            fingerCount = n
            baseline = spread / lastRatio
        }
        let ratio = spread / baseline
        lastRatio = ratio
        // Light smoothing takes the jitter out without adding noticeable lag.
        smoothed += (ratio - smoothed) * 0.6
        let tx = (cx - startCenter.0) * Self.aspect, ty = cy - startCenter.1
        return [.changed(ratio: CGFloat(smoothed), travel: CGFloat((tx * tx + ty * ty).squareRoot()))]
    }
}
