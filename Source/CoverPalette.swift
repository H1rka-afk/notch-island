import AppKit
import SwiftUI

// 3.19.0 — the live colours of the current cover. Recomputed (24×24 px,
// off the main thread) only when the cover changes; changes animate.
final class CoverPalette: ObservableObject {
    static let shared = CoverPalette()

    static let fallback: [PaletteRGB] = [
        PaletteRGB(r: 0.45, g: 0.4, b: 1.0), PaletteRGB(r: 0.85, g: 0.35, b: 0.85),
        PaletteRGB(r: 1.0, g: 0.4, b: 0.55), PaletteRGB(r: 0.3, g: 0.6, b: 1.0)
    ]

    @Published private(set) var colors: [PaletteRGB] = CoverPalette.fallback
    private weak var source: NSImage?
    private var hasSource = false
    private let queue = DispatchQueue(label: "app.notchisland.coverpalette", qos: .utility)

    func update(from image: NSImage?) {
        if let image, image === source { return }
        if image == nil && !hasSource { return }
        source = image
        hasSource = image != nil
        guard let image else { publish(Self.fallback); return }
        queue.async { [weak self] in
            let pixels = Self.pixels(of: image)
            let palette = CoverPaletteMath.palette(from: pixels)
            DispatchQueue.main.async { self?.publish(palette.isEmpty ? Self.fallback : palette) }
        }
    }

    private func publish(_ palette: [PaletteRGB]) {
        guard palette != colors else { return }
        withAnimation(.easeInOut(duration: 0.9)) { colors = palette }
    }

    private static func pixels(of image: NSImage) -> [PaletteRGB] {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var result: [PaletteRGB] = []
        result.reserveCapacity(side * side)
        for i in 0..<(side * side) {
            let o = i * 4
            result.append(PaletteRGB(r: Double(data[o]) / 255, g: Double(data[o + 1]) / 255, b: Double(data[o + 2]) / 255))
        }
        return result
    }
}

extension PaletteRGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}
