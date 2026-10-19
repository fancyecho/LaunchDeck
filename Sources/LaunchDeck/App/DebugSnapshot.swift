#if DEBUG
import AppKit

/// Debug-only scripted runs that render the canvas to PNGs and quit, so the UI can
/// be checked without Screen Recording permission.
///
///   LAUNCHDECK_SNAPSHOT=<dir>        where PNGs go (required)
///   LAUNCHDECK_QUERY=<text>          type a search after opening
///   LAUNCHDECK_SCENARIO=folder|merge|reorder|page2
///   LAUNCHDECK_LAYOUT_FILE=<path>    use a scratch layout instead of the real one
enum DebugSnapshot {
    static func runIfRequested(window: NSWindow, canvas: LauncherCanvas) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["LAUNCHDECK_SNAPSHOT"] else { return }
        var steps: [(Double, () -> Void)] = [(1.4, {
            NSLog("LaunchDeck debug: pages \(canvas.pages.map { $0.map(\.id) })")
            capture(canvas, "\(dir)/browse.png")
        })]

        if let query = env["LAUNCHDECK_QUERY"] {
            steps.append((0.2, { type(query, into: canvas) }))
            steps.append((0.8, {
                NSLog("LaunchDeck debug: results for \(query): \(canvas.results.prefix(8).map(\.name))")
                capture(canvas, "\(dir)/search.png")
            }))
        }

        switch env["LAUNCHDECK_SCENARIO"] {
        case "folder"?:
            steps.append((0.1, {
                if let i = canvas.pages.first?.firstIndex(where: { $0.folder != nil }) {
                    canvas.activate(canvas.pages[0][i])
                }
            }))
            steps.append((0.9, { capture(canvas, "\(dir)/folder.png") }))
        case "dragout"?:
            // Open the first folder, drag its first app out past the panel and drop it on the grid.
            steps.append((0.1, {
                if let i = canvas.pages.first?.firstIndex(where: { $0.folder != nil }) {
                    canvas.activate(canvas.pages[0][i])
                }
            }))
            var start = CGPoint.zero
            steps.append((0.8, {
                let c = canvas.folderCenter(0, columns: canvas.folder?.columns ?? 6)
                let m = canvas.folder?.metrics ?? canvas.metrics
                let local = CGPoint(x: c.x, y: c.y - TileLayer.size(for: m).height / 2 + m.iconSize / 2)
                start = canvas.folderStrip.convert(local, to: canvas.root)
                mouse(.leftMouseDown, start, window)
            }))
            steps.append((0.05, { mouse(.leftMouseDragged, CGPoint(x: start.x + 20, y: start.y), window) }))
            steps.append((0.1, { mouse(.leftMouseDragged, CGPoint(x: 60, y: canvas.metrics.size.height * 0.5), window) }))
            steps.append((0.5, { mouse(.leftMouseDragged, iconCenter(canvas, 2), window) }))
            steps.append((0.4, { capture(canvas, "\(dir)/dragout-hover.png") }))
            steps.append((0.05, { mouse(.leftMouseUp, iconCenter(canvas, 2), window) }))
            steps.append((0.7, {
                NSLog("LaunchDeck debug: after dragout \(canvas.pages.first?.prefix(4).map(\.id) ?? [])")
                capture(canvas, "\(dir)/dragout-done.png")
            }))
        case "refolder"?:
            // Close one folder and open another before the close animation ends.
            func openFolder(_ n: Int) {
                guard canvas.pages.count > 1 else { return }
                let folders = canvas.pages[1].filter { $0.folder != nil }
                if n < folders.count { canvas.activate(folders[n]) }
            }
            steps.append((0.1, { canvas.goTo(page: 1) }))
            steps.append((0.6, { openFolder(1) }))
            steps.append((0.7, { canvas.closeFolder(animated: true) }))
            steps.append((0.1, { openFolder(0) }))
            steps.append((0.9, {
                NSLog("LaunchDeck debug: folder tiles \(canvas.folderStrip.sublayers?.count ?? 0) for \(canvas.folder?.apps.count ?? -1) apps")
                capture(canvas, "\(dir)/refolder.png")
            }))
        case "comet"?:
            // Sweep the pointer across empty space below the grid.
            let y = canvas.metrics.size.height - 30
            for i in 0..<14 {
                steps.append((0.016, { canvas.pointerMoved(to: CGPoint(x: 300 + CGFloat(i) * 38, y: y - CGFloat(i) * 6)) }))
            }
            steps.append((0.02, { capture(canvas, "\(dir)/comet.png") }))
            // Then a slow drift, which should stay just as soft.
            steps.append((0.5, {}))
            for i in 0..<14 {
                steps.append((0.016, { canvas.pointerMoved(to: CGPoint(x: 900 + CGFloat(i) * 7, y: y - 20 - CGFloat(i) * 1.5)) }))
            }
            steps.append((0.02, { capture(canvas, "\(dir)/comet-slow.png") }))
        case "dragout2"?:
            // Same as dragout but from a folder on page 2, dropped into a gap; the
            // mid-flight capture shows where the icon lands from.
            steps.append((0.1, { canvas.goTo(page: 1) }))
            steps.append((0.6, {
                if canvas.pages.count > 1, let f = canvas.pages[1].first(where: { $0.folder != nil }) { canvas.activate(f) }
            }))
            var start2 = CGPoint.zero
            let gap = CGPoint(x: canvas.metrics.center(for: 9).x - canvas.metrics.cell.width * 0.45,
                              y: canvas.metrics.center(for: 9).y)
            steps.append((0.8, {
                let c = canvas.folderCenter(0, columns: canvas.folder?.columns ?? 6)
                let m = canvas.folder?.metrics ?? canvas.metrics
                let local = CGPoint(x: c.x, y: c.y - TileLayer.size(for: m).height / 2 + m.iconSize / 2)
                start2 = canvas.folderStrip.convert(local, to: canvas.root)
                mouse(.leftMouseDown, start2, window)
            }))
            steps.append((0.05, { mouse(.leftMouseDragged, CGPoint(x: start2.x + 20, y: start2.y), window) }))
            steps.append((0.1, { mouse(.leftMouseDragged, CGPoint(x: 60, y: canvas.metrics.size.height * 0.5), window) }))
            steps.append((0.5, { mouse(.leftMouseDragged, gap, window) }))
            steps.append((0.4, { mouse(.leftMouseUp, gap, window) }))
            steps.append((0.06, { capture(canvas, "\(dir)/dragout2-flight.png") }))
            steps.append((0.7, {
                NSLog("LaunchDeck debug: after dragout2 page2 \(canvas.pages[safe: 1]?.prefix(12).map(\.id) ?? [])")
                capture(canvas, "\(dir)/dragout2-done.png")
            }))
        case "merge"?:
            // Drag the first icon onto the second and hold until the folder forms.
            let a = iconCenter(canvas, 0), b = iconCenter(canvas, 1)
            steps.append((0.1, { mouse(.leftMouseDown, a, window) }))
            steps.append((0.05, { mouse(.leftMouseDragged, CGPoint(x: a.x + 20, y: a.y), window) }))
            steps.append((0.1, { mouse(.leftMouseDragged, b, window) }))
            steps.append((0.6, { capture(canvas, "\(dir)/merge-hover.png") }))
            steps.append((0.05, { mouse(.leftMouseUp, b, window) }))
            steps.append((0.8, {
                NSLog("LaunchDeck debug: after merge \(canvas.pages.first?.prefix(4).map(\.id) ?? [])")
                capture(canvas, "\(dir)/merge-done.png")
            }))
        case "reorder"?:
            // Drag the first icon to the gap between the 3rd and 4th.
            let a = iconCenter(canvas, 0)
            let c = canvas.metrics.center(for: 3)
            let target = CGPoint(x: c.x - canvas.metrics.cell.width * 0.42, y: c.y)
            steps.append((0.1, { mouse(.leftMouseDown, a, window) }))
            steps.append((0.05, { mouse(.leftMouseDragged, CGPoint(x: a.x + 20, y: a.y), window) }))
            steps.append((0.1, { mouse(.leftMouseDragged, target, window) }))
            steps.append((0.5, { capture(canvas, "\(dir)/reorder-hover.png") }))
            steps.append((0.05, { mouse(.leftMouseUp, target, window) }))
            steps.append((0.7, {
                NSLog("LaunchDeck debug: after reorder \(canvas.pages.first?.prefix(5).map(\.id) ?? [])")
                capture(canvas, "\(dir)/reorder-done.png")
            }))
        case "page2"?:
            steps.append((0.1, { canvas.goTo(page: 1) }))
            steps.append((0.9, {
                let c = canvas.metrics.center(for: 1)
                canvas.pointerMoved(to: CGPoint(x: c.x + 40, y: c.y - 30))
            }))
            steps.append((0.5, { capture(canvas, "\(dir)/page2.png") }))
        default:
            break
        }
        steps.append((0.1, { NSApp.terminate(nil) }))
        run(steps)
    }

    private static func run(_ steps: [(Double, () -> Void)]) {
        guard let (delay, step) = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            step()
            run(Array(steps.dropFirst()))
        }
    }

    private static func iconCenter(_ canvas: LauncherCanvas, _ slot: Int) -> CGPoint {
        let c = canvas.metrics.center(for: slot)
        return CGPoint(x: c.x, y: c.y - TileLayer.size(for: canvas.metrics).height / 2 + canvas.metrics.iconSize / 2)
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ window: NSWindow) {
        guard let view = window.contentView,
              let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: view.bounds.height - p.y),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1)
        else { return }
        window.sendEvent(event)
    }

    private static func type(_ text: String, into canvas: LauncherCanvas) {
        for ch in text {
            let s = String(ch)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: s,
                                        charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                _ = canvas.handleKey(e)
            }
        }
    }

    private static func capture(_ canvas: LauncherCanvas, _ path: String) {
        guard let layer = canvas.layer else { return }
        let size = canvas.bounds.size
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        // The layer tree is y-down; flip the bitmap context to match.
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        (layer.presentation() ?? layer).render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSLog("LaunchDeck debug: wrote \(path)")
    }
}
#endif
