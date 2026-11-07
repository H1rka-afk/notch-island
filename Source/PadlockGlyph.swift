import SwiftUI

// 4.17.1 — a padlock that really opens, instead of a cross-fade from
// «lock.fill» to «lock.open.fill». 4.17.2: drawn in the proportions of the
// system «lock.fill» (wide rounded body, no keyhole, thick shackle), and the
// shackle now swings open on the point where its RIGHT leg enters the body —
// the right leg never leaves the body, only the left leg comes out.
// The closed state is the same drawing on the lock screen and the desktop.
struct PadlockGlyph: View {
    let open: Bool
    var size: CGFloat = 18
    var color: Color = .white.opacity(0.94)

    @State private var swing: Double = 0     // degrees, clockwise around the right leg's base
    @State private var token = UUID()

    private static let openAngle: Double = 34

    var body: some View {
        let bodyW = size * 0.82
        let bodyH = size * 0.52
        let line = size * 0.135
        let outerW = size * 0.52                // shackle, outer edge to outer edge
        let pathW = outerW - line               // centre line of the stroke
        let sink = line * 0.9                   // how deep the legs go into the body
        let pathH = size * 0.5 - line / 2 + sink
        ZStack(alignment: .bottom) {
            Shackle()
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                .frame(width: pathW, height: pathH)
                // Pivot: the right leg's centre, exactly at the top of the body.
                .rotationEffect(.degrees(swing),
                                anchor: UnitPoint(x: 1, y: 1 - sink / pathH))
                .offset(y: -(bodyH - sink))
            RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                .fill(color)
                .frame(width: bodyW, height: bodyH)
        }
        .frame(width: size, height: size, alignment: .bottom)
        .onAppear { apply(open, animated: false) }
        .onChange(of: open) { apply($0, animated: true) }
        .accessibilityHidden(true)
    }

    private func apply(_ isOpen: Bool, animated: Bool) {
        let current = UUID()
        token = current
        let target = isOpen ? Self.openAngle : 0
        guard animated else { swing = target; return }
        if isOpen {
            // A quick pull, then the left leg springs up and out, settling
            // with a small bounce — the right leg stays in the body throughout.
            withAnimation(.easeIn(duration: 0.07)) { swing = -3 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                guard token == current else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { swing = target }
            }
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { swing = 0 }
        }
    }
}

// An upside-down U: two legs joined by a half circle (stroke centre line).
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
