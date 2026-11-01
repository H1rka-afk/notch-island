import Foundation

// 3.19.0 — the colours of a cover for the «Обложка» theme (pure, tested).
struct PaletteRGB: Equatable, Codable {
    var r: Double, g: Double, b: Double

    var hsb: (h: Double, s: Double, v: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b), d = maxV - minV
        var h = 0.0
        if d > 0 {
            if maxV == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxV == 0 ? 0 : d / maxV, maxV)
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(h: Double, s: Double, v: Double) {
        let hh = (h - floor(h)) * 6
        let i = Int(hh) % 6, f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
    }

    func scaled(_ k: Double) -> PaletteRGB { PaletteRGB(r: r * k, g: g * k, b: b * k) }
}

enum CoverPaletteMath {
    // Up to `count` vivid colours, the most present first. Grey covers give
    // an empty list (the theme then uses its default colours).
    static func palette(from pixels: [PaletteRGB], count: Int = 4) -> [PaletteRGB] {
        let binCount = 12
        var weight = [Double](repeating: 0, count: binCount)
        var hx = [Double](repeating: 0, count: binCount), hy = hx, sat = hx, val = hx
        for pixel in pixels {
            let c = pixel.hsb
            guard c.s >= 0.18, c.v >= 0.15 else { continue }
            let w = c.s * c.v
            let bin = min(binCount - 1, Int(c.h * Double(binCount)))
            weight[bin] += w
            hx[bin] += cos(c.h * 2 * .pi) * w
            hy[bin] += sin(c.h * 2 * .pi) * w
            sat[bin] += c.s * w
            val[bin] += c.v * w
        }
        let total = weight.reduce(0, +)
        guard total > 0 else { return [] }
        let order = (0..<binCount).filter { weight[$0] > total * 0.03 }.sorted { weight[$0] > weight[$1] }
        var result: [PaletteRGB] = order.prefix(count).map { bin in
            var hue = atan2(hy[bin], hx[bin]) / (2 * .pi)
            if hue < 0 { hue += 1 }
            let s = min(0.9, max(0.55, sat[bin] / weight[bin]))
            let v = min(0.95, max(0.78, val[bin] / weight[bin]))
            return PaletteRGB(h: hue, s: s, v: v)
        }
        // Too few colours on the cover: neighbours of the main hue.
        if let first = result.first?.hsb {
            var shift = 1
            while result.count < count {
                let step = Double((shift + 1) / 2) * (shift % 2 == 1 ? 1 : -1) * 0.08
                result.append(PaletteRGB(h: first.h + step, s: first.s, v: max(0.78, first.v - 0.05 * Double(shift))))
                shift += 1
            }
        }
        return result
    }
}
