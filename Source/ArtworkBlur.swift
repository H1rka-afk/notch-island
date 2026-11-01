import AppKit
import CoreImage

// 3.18.0 — the cover, blurred and brightened, to fill the waveform bars
// like the Dynamic Island on iPhone. Made once per cover at 48 px (a few
// milliseconds) and cached, so each animation frame only masks a tiny image.
enum ArtworkBlur {
    static let enabledKey = "waveArtworkV3180"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }

    // Keeps the source alive, so an identical address can never be reused.
    private static var cache: (source: NSImage, image: NSImage)?
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func blurred(_ source: NSImage?) -> NSImage? {
        guard let source else { return nil }
        if let cache, cache.source === source { return cache.image }
        guard let made = make(source) else { return nil }
        cache = (source, made)
        return made
    }

    private static func make(_ source: NSImage) -> NSImage? {
        // Downscale first: blurring a 48-px picture is nearly free.
        let side = 48
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let small = CIImage(bitmapImageRep: rep) else { return nil }

        var image = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 3.5)
            .cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7,
                                                            kCIInputContrastKey: 1.05])
        // Dark covers would vanish on the black island: lift them.
        let luminance = averageLuminance(image)
        if luminance < 0.42 {
            let ev = min(2.2, (0.42 - luminance) * 5 + 0.4)
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        guard let cg = context.createCGImage(image, from: small.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    private static func averageLuminance(_ image: CIImage) -> Double {
        let average = image.applyingFilter("CIAreaAverage",
                                           parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
