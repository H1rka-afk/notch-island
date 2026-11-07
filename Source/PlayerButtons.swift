import SwiftUI

// 4.18.0 — media buttons that move like the iPhone Dynamic Island player
// (from the user's screen recording):
//  • pressing: a soft grey circle appears behind the button and the icon
//    shrinks a little; after release the circle fades out;
//  • ⏩ / ⏪: the triangles step — the front one shrinks away, the back one
//    slides into its place and a new one grows in behind it;
//  • ⏯: pause shrinks away while play grows in (and back).

struct IPhoneControlStyle: ButtonStyle {
    var diameter: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        PressHighlight(pressed: configuration.isPressed, diameter: diameter) {
            configuration.label
        }
    }
}

private struct PressHighlight<Label: View>: View {
    let pressed: Bool
    let diameter: CGFloat
    @ViewBuilder let label: () -> Label

    @State private var shown = false
    @State private var pressedAt = Date.distantPast

    var body: some View {
        label()
            .foregroundStyle(Color.white)
            .scaleEffect(pressed ? 0.86 : 1)
            .animation(pressed ? .easeOut(duration: 0.1) : .spring(response: 0.34, dampingFraction: 0.62),
                       value: pressed)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(shown ? 1 : 0.7)
                    .opacity(shown ? 1 : 0)
            )
            .contentShape(Rectangle())
            .onChange(of: pressed) { isPressed in
                if isPressed {
                    pressedAt = Date()
                    withAnimation(.easeOut(duration: 0.12)) { shown = true }
                } else {
                    // Keep the circle visible a moment even after a quick click.
                    let wait = max(0, 0.18 - Date().timeIntervalSince(pressedAt))
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                        withAnimation(.easeOut(duration: 0.34)) { shown = false }
                    }
                }
            }
    }
}

// ⏩ drawn from three triangles so they can step. `pulse` changes on every
// press (state.nextPulse / previousPulse).
struct SkipGlyph: View {
    let forward: Bool
    let pulse: Int
    var size: CGFloat = 22

    @State private var step: CGFloat = 0     // 0 at rest → 1 stepped

    var body: some View {
        let w = size * 0.6
        let h = size * 0.7
        ZStack(alignment: .leading) {
            // The new triangle, growing in at the back.
            RoundedTriangle()
                .frame(width: w, height: h)
                .scaleEffect(step, anchor: .trailing)
                .opacity(Double(step))
            // The back triangle slides into the front place.
            RoundedTriangle()
                .frame(width: w, height: h)
                .offset(x: step * w)
            // The front triangle shrinks away.
            RoundedTriangle()
                .frame(width: w, height: h)
                .scaleEffect(1 - step * 0.9, anchor: .leading)
                .opacity(Double(1 - step))
                .offset(x: w + step * w * 0.25)
        }
        .frame(width: w * 2, height: h, alignment: .leading)
        .scaleEffect(x: forward ? 1 : -1, y: 1)
        .onChange(of: pulse) { _ in
            step = 0
            withAnimation(.easeInOut(duration: 0.3)) { step = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                // Same picture as at rest, so the reset is invisible.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { step = 0 }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RoundedTriangle: View {
    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) * 0.16
            let path = Path { p in
                p.move(to: CGPoint(x: r * 0.6, y: r * 0.7))
                p.addLine(to: CGPoint(x: g.size.width - r * 0.6, y: g.size.height / 2))
                p.addLine(to: CGPoint(x: r * 0.6, y: g.size.height - r * 0.7))
                p.closeSubpath()
            }
            ZStack {
                path.fill(Color.white)
                path.stroke(Color.white, style: StrokeStyle(lineWidth: r * 1.2, lineJoin: .round))
            }
        }
    }
}

struct PlayPauseGlyph: View {
    let playing: Bool
    var size: CGFloat = 27

    var body: some View {
        ZStack {
            Image(systemName: "pause.fill")
                .scaleEffect(playing ? 1 : 0.3)
                .opacity(playing ? 1 : 0)
            Image(systemName: "play.fill")
                .scaleEffect(playing ? 0.3 : 1)
                .opacity(playing ? 0 : 1)
        }
        .font(.system(size: size, weight: .semibold))
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: playing)
        .accessibilityLabel(playing ? "Пауза" : "Играть")
    }
}
