import AppKit
import CoreImage

// 3.18.0 — the cover, blurred and brightened, to fill the waveform bars
// like the Dynamic Island on iPhone. Made once per cover at 48 px (a few
// milliseconds) and cached, so each animation frame only masks a tiny image.
enum ArtworkBlur {
    static let enabledKey = "waveArtworkV3180"
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }

    // Keeps the source alive, so an identical address can never be reused.
    private static var cache: (source: NSImage, sigma: Double, image: NSImage)?
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    // 4.8.3: the blur strength is chosen in Settings (0 … 1).
    static func blurred(_ source: NSImage?, amount: Double? = nil) -> NSImage? {
        guard let source else { return nil }
        let a = min(1, max(0, amount ?? WaveLook.blur))
        let sigma = (0.4 + 7.6 * a).rounded(toPlaces: 1)
        if let cache, cache.source === source, cache.sigma == sigma { return cache.image }
        guard let made = make(source, sigma: sigma) else { return nil }
        cache = (source, sigma, made)
        return made
    }

    private static func make(_ source: NSImage, sigma: Double) -> NSImage? {
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
            .applyingGaussianBlur(sigma: sigma)
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

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let k = pow(10.0, Double(places))
        return (self * k).rounded() / k
    }
}

// 4.8.3 — how the waveform looks: the blurred cover inside the bars (as on
// iPhone), one colour taken from the cover, or the user's own colour; how
// blurred the cover is and how big the bars are.
enum WaveLook {
    static let styleKey = "waveStyleV483"
    static let colorKey = "waveColorV483"
    static let blurKey = "waveBlurV483"
    static let sizeKey = "waveSizeV483"
    // 4.8.4: frames per second of the waveform.
    static let fpsKey = "waveFPSV484"
    static let fpsChoices = [15, 24, 30, 60, 120]
    static var fps: Int {
        let v = UserDefaults.standard.integer(forKey: fpsKey)
        return fpsChoices.contains(v) ? v : 30
    }
    static let defaultBlur = 0.4
    static let defaultSize = 1.0

    static let styles: [(id: String, title: String)] = [
        ("artwork", "Обложка"), ("tint", "Цвет обложки"), ("custom", "Свой цвет")
    ]

    // The old «Обложка в полосах» switch decides the starting style.
    static var legacyStyle: String { ArtworkBlur.isEnabled ? "artwork" : "tint" }
    static var style: String { UserDefaults.standard.string(forKey: styleKey) ?? legacyStyle }
    static var blur: Double { (UserDefaults.standard.object(forKey: blurKey) as? Double) ?? 0.4 }
    static let defaultColor = PaletteRGB(r: 1.0, g: 0.36, b: 0.62)

    static func decodeColor(_ raw: String) -> PaletteRGB {
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3, parts.allSatisfy({ (0...1).contains($0) }) else { return defaultColor }
        return PaletteRGB(r: parts[0], g: parts[1], b: parts[2])
    }

    static func encodeColor(_ c: PaletteRGB) -> String {
        String(format: "%.4f,%.4f,%.4f", min(1, max(0, c.r)), min(1, max(0, c.g)), min(1, max(0, c.b)))
    }
}

// 4.8.4 — sizes of the island chosen in Settings.
enum IslandLook {
    static let expandedKey = "islandExpandedScaleV484"
    static let compactArtworkKey = "islandCompactArtworkScaleV484"
    static let expandedRange = 0.85...1.15
    static let compactArtworkRange = 0.75...1.25

    static var expandedScale: CGFloat {
        let v = (UserDefaults.standard.object(forKey: expandedKey) as? Double) ?? 1
        // 4.18.0: the open island is about 6 % smaller at every setting.
        return CGFloat(min(expandedRange.upperBound, max(expandedRange.lowerBound, v))) * 0.94
    }
    static var compactArtworkScale: CGFloat {
        let v = (UserDefaults.standard.object(forKey: compactArtworkKey) as? Double) ?? 1
        return CGFloat(min(compactArtworkRange.upperBound, max(compactArtworkRange.lowerBound, v)))
    }
}
