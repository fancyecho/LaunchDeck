import CoreGraphics
import Foundation

/// Screen-relative layout of the launcher: grid geometry, icon size and where the
/// search bar and page dots sit. Pure value type so views can compare it cheaply.
struct GridMetrics: Equatable {
    var size: CGSize = .zero
    var columns = 7
    var rows = 5
    var cell: CGSize = .zero
    var origin: CGPoint = .zero
    var iconSize: CGFloat = 80
    var searchBarY: CGFloat = 0
    var dotsY: CGFloat = 0

    var capacity: Int { columns * rows }
    var labelFontSize: CGFloat { min(max(iconSize * 0.135, 11), 15) }
    var labelSpacing: CGFloat { (iconSize * 0.1).rounded() }
    var itemWidth: CGFloat { min(cell.width - 6, iconSize * 1.55) }

    static let zero = GridMetrics()

    init() {}

    init(size: CGSize, topInset: CGFloat) {
        self.size = size
        let aspect = size.width / max(size.height, 1)
        columns = aspect > 2.1 ? 9 : (aspect < 1.45 ? 6 : 7)
        rows = 5

        searchBarY = topInset + max(48, size.height * 0.065)
        let gridTop = searchBarY + max(40, size.height * 0.05)
        dotsY = size.height - max(36, size.height * 0.05)
        let gridBottom = dotsY - max(24, size.height * 0.035)
        let side = size.width * (aspect > 2.1 ? 0.14 : 0.1)

        cell = CGSize(
            width: (size.width - side * 2) / CGFloat(columns),
            height: max(1, gridBottom - gridTop) / CGFloat(rows)
        )
        origin = CGPoint(x: side, y: gridTop)
        iconSize = min(cell.width * 0.58, cell.height * 0.6, 132).rounded()
    }

    func center(for slot: Int) -> CGPoint {
        let col = slot % columns
        let row = slot / columns
        return CGPoint(
            x: origin.x + cell.width * (CGFloat(col) + 0.5),
            y: origin.y + cell.height * (CGFloat(row) + 0.5)
        )
    }

    /// Delay for the open animation: icons near the centre land first and the
    /// motion ripples outward.
    func rippleDelay(for slot: Int) -> Double {
        let col = Double(slot % columns)
        let row = Double(slot / columns)
        let dx = (col - Double(columns - 1) / 2) / Double(columns)
        let dy = (row - Double(rows - 1) / 2) / Double(rows) * 0.8
        return hypot(dx, dy) * 0.24
    }
}
