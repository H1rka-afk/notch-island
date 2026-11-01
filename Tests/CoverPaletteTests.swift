import Foundation

// swiftc -parse-as-library Source/CoverPaletteMath.swift Tests/CoverPaletteTests.swift -o cp && ./cp
@main
struct CoverPaletteTests {
    static func main() {
        // HSB round trip.
        let c = PaletteRGB(r: 0.9, g: 0.3, b: 0.2)
        let back = PaletteRGB(h: c.hsb.h, s: c.hsb.s, v: c.hsb.v)
        precondition(abs(back.r - c.r) < 1e-9 && abs(back.g - c.g) < 1e-9 && abs(back.b - c.b) < 1e-9)

        // A red cover: four colours, the first one red.
        let red = [PaletteRGB](repeating: PaletteRGB(r: 0.85, g: 0.1, b: 0.1), count: 400)
        let p1 = CoverPaletteMath.palette(from: red)
        precondition(p1.count == 4)
        let h1 = p1[0].hsb.h
        precondition(h1 < 0.05 || h1 > 0.95, "\(h1)")

        // Mostly blue with some orange: blue first, orange present.
        let mixed = [PaletteRGB](repeating: PaletteRGB(r: 0.1, g: 0.3, b: 0.9), count: 300)
            + [PaletteRGB](repeating: PaletteRGB(r: 1.0, g: 0.55, b: 0.1), count: 100)
        let p2 = CoverPaletteMath.palette(from: mixed)
        let b = p2[0].hsb.h
        precondition(b > 0.55 && b < 0.7, "\(b)")
        precondition(p2.contains { $0.hsb.h > 0.05 && $0.hsb.h < 0.12 })

        // Colours are vivid even from a dull cover.
        precondition(p2.allSatisfy { $0.hsb.s >= 0.55 && $0.hsb.v >= 0.78 })

        // A grey cover: nothing (the theme uses its default colours).
        let grey = [PaletteRGB](repeating: PaletteRGB(r: 0.5, g: 0.5, b: 0.5), count: 400)
        precondition(CoverPaletteMath.palette(from: grey).isEmpty)
        print("CoverPaletteTests: OK")
    }
}
