import SwiftUI

// 5.0.0 — the lock-screen clock in several styles, with a font and a colour
// to choose. Every style keeps the same place as the macOS clock and is
// NEVER smaller than it — neither lower nor narrower — so the system clock
// can never peek out from under Ovira's (no condensed style on purpose).
enum LockClockStyle: String, CaseIterable, Identifiable {
    case classic, bold, thin, wide, glow

    static let key = "lockClockStyleV500"
    static var current: LockClockStyle {
        LockClockStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .classic
    }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Классика"
        case .bold: return "Крупные"
        case .thin: return "Тонкие"
        case .wide: return "Широкие"
        case .glow: return "Свечение"
        }
    }

    // Size as a share of the screen height (the macOS clock is ≈ 0.119 —
    // the smallest any style may be; see minimumFactor).
    static let minimumFactor: CGFloat = 0.119
    var sizeFactor: CGFloat { max(Self.minimumFactor, rawFactor) }
    private var rawFactor: CGFloat {
        switch self {
        case .classic: return 0.119
        case .bold: return 0.128
        case .thin: return 0.13
        case .wide: return 0.122
        case .glow: return 0.119
        }
    }

    var weight: Font.Weight {
        switch self {
        case .classic: return .medium
        case .bold: return .heavy
        case .thin: return .ultraLight
        case .wide: return .semibold
        case .glow: return .semibold
        }
    }
}

enum LockClockFont: String, CaseIterable, Identifiable {
    case rounded, system, serif, mono

    static let key = "lockClockFontV500"
    static var current: LockClockFont {
        LockClockFont(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .rounded
    }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rounded: return "Округлый"
        case .system: return "Системный"
        case .serif: return "С засечками"
        case .mono: return "Моно"
        }
    }

    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .system: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

enum LockClockColor: String, CaseIterable, Identifiable {
    case white, cover, yellow, pink, blue, mint, orange, purple

    static let key = "lockClockColorV500"
    static var current: LockClockColor {
        LockClockColor(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .white
    }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "Белый"
        case .cover: return "Под обложку"
        case .yellow: return "Жёлтый"
        case .pink: return "Розовый"
        case .blue: return "Голубой"
        case .mint: return "Мятный"
        case .orange: return "Оранжевый"
        case .purple: return "Сиреневый"
        }
    }

    // `cover` is the artwork's tint, lifted so it stays readable.
    func color(cover: Color) -> Color {
        switch self {
        case .white: return Color.white.opacity(0.92)
        case .cover: return cover
        case .yellow: return Color(red: 1.0, green: 0.86, blue: 0.35)
        case .pink: return Color(red: 1.0, green: 0.55, blue: 0.72)
        case .blue: return Color(red: 0.5, green: 0.8, blue: 1.0)
        case .mint: return Color(red: 0.55, green: 0.95, blue: 0.8)
        case .orange: return Color(red: 1.0, green: 0.66, blue: 0.3)
        case .purple: return Color(red: 0.78, green: 0.66, blue: 1.0)
        }
    }

    // Swatch in Settings (the «cover» one shows a gradient).
    var swatch: AnyShapeStyle {
        switch self {
        case .cover:
            return AnyShapeStyle(LinearGradient(colors: [.pink, .orange, .yellow, .mint, .blue],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        default:
            return AnyShapeStyle(color(cover: .white))
        }
    }
}

// The date line and the time, drawn at the macOS clock's place. `height`
// is the screen (or preview) height; `cover` is the artwork tint.
struct LockClockFace: View {
    let date: Date
    let width: CGFloat
    let height: CGFloat
    var cover: Color = .white
    var style: LockClockStyle = .current
    var font: LockClockFont = .current
    var colour: LockClockColor = .current

    var body: some View {
        let tint = colour.color(cover: cover)
        ZStack {
            Text(LockCoverWallpaper.date(date))
                .font(.system(size: height * 0.025, weight: .semibold, design: font == .mono ? .monospaced : font.design))
                .foregroundStyle(colour == .white ? Color.white.opacity(0.92) : tint.opacity(0.95))
                .position(x: width / 2, y: height * 0.1056)
            timeText(tint)
                .position(x: width / 2, y: height * 0.187)
        }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    }

    @ViewBuilder
    private func timeText(_ tint: Color) -> some View {
        let text = Text(LockCoverWallpaper.time(date))
            .font(.system(size: height * style.sizeFactor, weight: style.weight, design: font.design))
            .fontWidth(style == .wide ? .expanded : .standard)
            .monospacedDigit()
            .kerning(style == .bold ? -height * 0.002 : 0)
            .foregroundStyle(tint)
        if style == .glow {
            text
                .shadow(color: tint.opacity(0.9), radius: height * 0.012)
                .shadow(color: tint.opacity(0.6), radius: height * 0.035)
        } else {
            text
        }
    }
}

// MARK: Settings — live preview and style chips

struct LockClockPreview: View {
    let style: LockClockStyle
    let font: LockClockFont
    let colour: LockClockColor

    var body: some View {
        let screenH: CGFloat = 560
        TimelineView(.everyMinute) { context in
            LockClockFace(date: context.date, width: 360, height: screenH,
                          cover: Color(red: 1.0, green: 0.55, blue: 0.62),
                          style: style, font: font, colour: colour)
                .frame(width: 360, height: screenH)
                .offset(y: -screenH * 0.072)
                .frame(width: 360, height: screenH * 0.17, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.32, green: 0.12, blue: 0.22),
                                              Color(red: 0.1, green: 0.08, blue: 0.2)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .animation(IslandMotion.surface, value: style)
        .animation(IslandMotion.surface, value: font)
        .animation(IslandMotion.surface, value: colour)
    }
}

struct LockClockChip: View {
    let style: LockClockStyle
    let font: LockClockFont
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                let text = Text("9:41")
                    .font(.system(size: 19, weight: style.weight, design: font.design))
                    .fontWidth(style == .wide ? .expanded : .standard)
                    .foregroundStyle(Color.white)
                Group {
                    if style == .glow {
                        text.shadow(color: .white.opacity(0.9), radius: 4)
                    } else {
                        text
                    }
                }
                .frame(height: 30)
                Text(style.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
