import AppKit
import QuartzCore

/// A small comet that rides under the pointer: a soft head and a misty tail along
/// where the pointer was over the last fraction of a second. The tail is made of
/// many overlapping radial glows spread evenly along the path, so it reads as a
/// wisp of light with no hard edges. Each glow's strength scales with the spacing,
/// keeping the brightness per length the same whether the move is fast or slow.
/// When the pointer rests, the tail shrinks back into the head.
final class CometTrail: PlainLayer {
    static let trailDuration: CFTimeInterval = 0.2

    private let halo = CometTrail.glow(size: 46, alpha: 0.26)
    private let core = CometTrail.glow(size: 9, alpha: 0.95)
    private var puffs: [CAGradientLayer] = []
    private var history: [(point: CGPoint, time: CFTimeInterval)] = []
    private static let puffCount = 56
    private static let pathSamples = 24

    /// Off under Reduce Motion: just the head, no tail.
    var showsTail = true

    override init() {
        super.init()
        for _ in 0..<Self.puffCount {
            let g = Self.glow(size: 20, alpha: 1)
            addSublayer(g)
            puffs.append(g)
        }
        addSublayer(halo)
        addSublayer(core)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private static func glow(size: CGFloat, alpha: CGFloat) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        g.type = .radial
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        // Slightly cool white, like starlight; falls off smoothly to nothing.
        let c = NSColor(srgbRed: 0.86, green: 0.94, blue: 1, alpha: 1)
        g.colors = [c.withAlphaComponent(alpha).cgColor, c.withAlphaComponent(alpha * 0.45).cgColor,
                    c.withAlphaComponent(alpha * 0.12).cgColor, c.withAlphaComponent(0).cgColor]
        g.locations = [0, 0.3, 0.65, 1]
        g.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return g
    }

    /// Snaps the whole comet to `p` with no tail.
    func reset(at p: CGPoint) {
        history = [(p, CACurrentMediaTime())]
        _ = step(now: CACurrentMediaTime() + Self.trailDuration)
    }

    func add(_ p: CGPoint, at time: CFTimeInterval) {
        history.append((p, time))
    }

    /// Lays the tail out for time `now`. Returns false once it has collapsed into
    /// the head, so the caller can stop ticking.
    func step(now: CFTimeInterval) -> Bool {
        guard let last = history.last else { return false }
        // Keep just enough history to cover the tail, but always the latest point.
        let cutoff = now - Self.trailDuration - 0.05
        if let keep = history.firstIndex(where: { $0.time >= cutoff }) {
            if keep > 0 { history.removeFirst(min(keep, history.count - 1)) }
        } else {
            history = [last]
        }

        // Sample the path from the tail's far end to the head, then spread the
        // glows evenly by distance so slow and fast segments look the same.
        var points: [CGPoint] = []
        var cumulative: [CGFloat] = [0]
        for i in stride(from: Self.pathSamples, through: 0, by: -1) {
            let p = position(at: now - Self.trailDuration * Double(i) / Double(Self.pathSamples))
            if let prev = points.last { cumulative.append(cumulative[cumulative.count - 1] + hypot(p.x - prev.x, p.y - prev.y)) }
            points.append(p)
        }
        let length = cumulative.last ?? 0
        let visible = showsTail && length > 2
        let spacing = length / CGFloat(Self.puffCount - 1)

        Motion.instantly {
            halo.position = last.point
            core.position = last.point
            var segment = 1
            for (i, g) in puffs.enumerated() {
                guard visible else { g.opacity = 0; continue }
                let u = CGFloat(i) / CGFloat(Self.puffCount - 1)  // 0 far end … 1 head
                let target = u * length
                while segment < cumulative.count - 1, cumulative[segment] < target { segment += 1 }
                let a = points[segment - 1], b = points[segment]
                let span = cumulative[segment] - cumulative[segment - 1]
                let f = span > 0 ? (target - cumulative[segment - 1]) / span : 0
                g.position = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)

                let size = 12 + 18 * pow(u, 1.3)
                g.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                // Constant brightness per length: denser glows each get fainter.
                let density = min(0.3, 0.55 * spacing / size)
                g.opacity = Float(density * pow(u, 1.7))
            }
        }
        return now - last.time < Self.trailDuration + 0.02
    }

    /// Pointer position at `t`, interpolated along the recorded path.
    private func position(at t: CFTimeInterval) -> CGPoint {
        guard let last = history.last, let first = history.first else { return .zero }
        if t >= last.time { return last.point }
        if t <= first.time { return first.point }
        var i = history.count - 1
        while i > 0, history[i - 1].time > t { i -= 1 }
        let a = history[i - 1], b = history[i]
        let span = b.time - a.time
        let f = span > 0 ? CGFloat((t - a.time) / span) : 1
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f)
    }
}
