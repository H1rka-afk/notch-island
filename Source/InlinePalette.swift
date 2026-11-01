import SwiftUI

// 4.5.3 — a colour palette right inside Settings (no separate system colour
// window): ready swatches, then hue, saturation and brightness sliders and
// a live sample. Works on PaletteRGB.
struct InlineColorPalette: View {
    @Binding var color: PaletteRGB

    static let swatches: [PaletteRGB] = [
        PaletteRGB(r: 1, g: 1, b: 1), PaletteRGB(r: 0.67, g: 0.63, b: 0.59), PaletteRGB(r: 0.6, g: 0.6, b: 0.62),
        PaletteRGB(r: 1.0, g: 0.27, b: 0.23), PaletteRGB(r: 1.0, g: 0.58, b: 0.0), PaletteRGB(r: 1.0, g: 0.8, b: 0.0),
        PaletteRGB(r: 0.2, g: 0.78, b: 0.35), PaletteRGB(r: 0.19, g: 0.69, b: 0.78), PaletteRGB(r: 0.04, g: 0.52, b: 1.0),
        PaletteRGB(r: 0.36, g: 0.35, b: 0.9), PaletteRGB(r: 0.69, g: 0.32, b: 0.87), PaletteRGB(r: 1.0, g: 0.18, b: 0.33),
        PaletteRGB(r: 0.64, g: 0.52, b: 0.37), PaletteRGB(r: 0.95, g: 0.75, b: 0.85)
    ]

    var body: some View {
        let hsb = color.hsb
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.color)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 7), spacing: 8) {
                    ForEach(0..<Self.swatches.count, id: \.self) { i in
                        let swatch = Self.swatches[i]
                        Button { withAnimation(.easeOut(duration: 0.2)) { color = swatch } } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                                .overlay(Circle().strokeBorder(Color.accentColor,
                                                               lineWidth: Self.close(swatch, color) ? 2.5 : 0)
                                            .padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            PaletteSlider(title: "Оттенок", value: hsb.h,
                          gradient: (0...12).map { PaletteRGB(h: Double($0) / 12, s: 0.9, v: 1).color }) { h in
                color = PaletteRGB(h: h, s: max(hsb.s, 0.05), v: max(hsb.v, 0.05))
            }
            PaletteSlider(title: "Насыщенность", value: hsb.s,
                          gradient: [PaletteRGB(h: hsb.h, s: 0, v: max(hsb.v, 0.3)).color,
                                     PaletteRGB(h: hsb.h, s: 1, v: max(hsb.v, 0.3)).color]) { s in
                color = PaletteRGB(h: hsb.h, s: s, v: hsb.v)
            }
            PaletteSlider(title: "Яркость", value: hsb.v,
                          gradient: [Color.black, PaletteRGB(h: hsb.h, s: hsb.s, v: 1).color]) { v in
                color = PaletteRGB(h: hsb.h, s: hsb.s, v: v)
            }
        }
    }

    static func close(_ a: PaletteRGB, _ b: PaletteRGB) -> Bool {
        abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) < 0.03
    }
}

struct PaletteSlider: View {
    let title: String
    let value: Double
    let gradient: [Color]
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(x: CGFloat(min(1, max(0, value))) * (width - 18))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    onChange(Double(min(1, max(0, (drag.location.x - 9) / (width - 18)))))
                })
            }
            .frame(height: 18)
        }
    }
}
