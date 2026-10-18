import AppKit
import CoreImage

/// Produces the heavily blurred desktop picture used as the launcher backdrop,
/// the same treatment the classic Launchpad applied.
enum WallpaperRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(url: URL, pixelSize: CGSize) -> CGImage? {
        guard pixelSize.width > 0, pixelSize.height > 0,
              let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        else { return nil }
        let extent = source.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return nil }

        let scale = max(pixelSize.width / extent.width, pixelSize.height / extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e = scaled.extent
        let crop = CGRect(
            x: (e.midX - pixelSize.width / 2).rounded(),
            y: (e.midY - pixelSize.height / 2).rounded(),
            width: pixelSize.width, height: pixelSize.height
        )

        let blurred = scaled
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(pixelSize.width) / 28)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35,
                kCIInputBrightnessKey: -0.02,
            ])
            .cropped(to: crop)

        return context.createCGImage(blurred, from: crop)
    }
}
