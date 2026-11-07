import SwiftUI

// 4.17.1 — a padlock that really opens: the shackle slides up out of the
// body, then turns around its right leg (with a small settle), instead of
// a cross-fade from «lock.fill» to «lock.open.fill». Drawn from shapes so the
// closed state is identical on the lock screen and on the desktop.
struct PadlockGlyph: View {
    let open: Bool
    var size: CGFloat = 18
    var color: Color = .white.opacity(0.94)

    @State private var lift: CGFloat = 0     // 0…1 — shackle out of the body
    @State private var swing: Double = 0     // degrees around the right leg
    @State private var token = UUID()

    var body: some View {
        let bodyW = size * 0.78
        let bodyH = size * 0.56
        let shackleW = size * 0.52
        let shackleH = size * 0.5
        let line = size * 0.13
        ZStack(alignment: .bottom) {
            Shackle()
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                .frame(width: shackleW, height: shackleH)
                // Like a real padlock: the shackle turns around its long
                // right leg, so the short leg swings out to the right.
                .rotation3DEffect(.degrees(swing), axis: (x: 0, y: 1, z: 0),
                                  anchor: UnitPoint(x: 1 - (line / 2) / shackleW, y: 0.5),
                                  perspective: 0.45)
                .offset(y: -(bodyH - line * 0.6) - lift * size * 0.2)
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                .fill(color)
                .frame(width: bodyW, height: bodyH)
                .overlay(
                    // keyhole
                    Capsule()
                        .fill(Color.black)
                        .frame(width: size * 0.1, height: size * 0.2)
                        .offset(y: size * 0.02)
                )
        }
        .frame(width: size, height: size, alignment: .bottom)
        .onAppear { apply(open, animated: false) }
        .onChange(of: open) { apply($0, animated: true) }
        .accessibilityHidden(true)
    }

    private func apply(_ isOpen: Bool, animated: Bool) {
        let current = UUID()
        token = current
        guard animated else {
            lift = isOpen ? 1 : 0
            swing = isOpen ? 180 : 0
            return
        }
        if isOpen {
            // 1) the shackle pops up out of the body…
            withAnimation(.easeOut(duration: 0.16)) { lift = 1 }
            // 2) …then turns around its right leg and settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                guard token == current else { return }
                withAnimation(.spring(response: 0.46, dampingFraction: 0.7)) { swing = 180 }
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { swing = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard token == current else { return }
                withAnimation(.easeIn(duration: 0.14)) { lift = 0 }
            }
        }
    }
}

// An upside-down U: two legs joined by a half circle.
private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}
