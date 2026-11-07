import AppKit
import IOKit
import SwiftUI

// 4.17.0 — a Face ID–style flourish on the padlock island when the Mac was
// unlocked WITHOUT typing the password (Touch ID or Apple Watch). Purely
// decorative: macOS does the unlocking, Ovira only draws the glyph.
enum FaceUnlockStyle {
    static let key = "unlockFaceIDStyleV4170"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

// Tells a typed password from Touch ID. While the screen is locked it watches
// only WHEN the keyboard was used — never which key: the HID idle clock
// restarting with the pointer still and no click, or the key-down clock
// moving. Several presses just before the unlock = a password was typed.
final class PasswordEntryProbe {
    static let shared = PasswordEntryProbe()
    private var timer: Timer?
    private var presses = 0
    private var lastPress: Date?
    private var lastIdle: Double = .infinity
    private var lastKeyAge: CFTimeInterval = .infinity
    private var lastMouse = NSPoint.zero

    func start() {
        stop()
        presses = 0
        lastPress = nil
        lastIdle = Self.hardwareIdleSeconds() ?? .infinity
        lastKeyAge = Self.keyAge()
        lastMouse = NSEvent.mouseLocation
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Read once, at the unlock moment.
    var typedPassword: Bool {
        sample()
        guard presses >= 3, let lastPress else { return false }
        return Date().timeIntervalSince(lastPress) < 3
    }

    private func sample() {
        let idle = Self.hardwareIdleSeconds() ?? .infinity
        let key = Self.keyAge()
        let mouse = NSEvent.mouseLocation
        defer { lastIdle = idle; lastKeyAge = key; lastMouse = mouse }
        let keyMoved = key + 0.02 < lastKeyAge
        let hidMoved = idle + 0.02 < lastIdle && mouse == lastMouse && Self.clickAge() > 0.35
        if keyMoved || hidMoved {
            // A typed password is many presses within seconds of each other.
            if let lastPress, Date().timeIntervalSince(lastPress) > 6 { presses = 0 }
            presses += 1
            lastPress = Date()
        }
    }

    private static func keyAge() -> CFTimeInterval {
        min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown))
    }

    private static func clickAge() -> CFTimeInterval {
        min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .rightMouseDown))
    }

    private static func hardwareIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        else { return nil }
        return value.doubleValue / 1_000_000_000
    }
}

// The glyph: four corner brackets around a simple face. While scanning the
// face turns a little from side to side and the brackets breathe; on success
// the face draws itself into a check mark.
struct FaceIDGlyph: View {
    let success: Bool
    var size: CGFloat = 20
    @State private var turn = false

    var body: some View {
        ZStack {
            FaceIDBrackets()
                .stroke(Color.white.opacity(0.94),
                        style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round))
                .scaleEffect(success ? 1 : (turn ? 0.92 : 1.0))
            FaceIDFace()
                .stroke(Color.white.opacity(0.94),
                        style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
                .rotation3DEffect(.degrees(turn ? 24 : -24), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .opacity(success ? 0 : 1)
                .scaleEffect(success ? 0.6 : 1)
            FaceIDCheck()
                .trim(from: 0, to: success ? 1 : 0)
                .stroke(Color(red: 0.36, green: 0.9, blue: 0.48),
                        style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: success)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.36).repeatForever(autoreverses: true)) { turn = true }
        }
        .accessibilityHidden(true)
    }
}

private struct FaceIDBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.28
        let r = rect.width * 0.12
        var p = Path()
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        // top-left
        p.move(to: CGPoint(x: minX, y: minY + arm))
        p.addLine(to: CGPoint(x: minX, y: minY + r))
        p.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        p.addLine(to: CGPoint(x: minX + arm, y: minY))
        // top-right
        p.move(to: CGPoint(x: maxX - arm, y: minY))
        p.addLine(to: CGPoint(x: maxX - r, y: minY))
        p.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
        p.addLine(to: CGPoint(x: maxX, y: minY + arm))
        // bottom-right
        p.move(to: CGPoint(x: maxX, y: maxY - arm))
        p.addLine(to: CGPoint(x: maxX, y: maxY - r))
        p.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY), control: CGPoint(x: maxX, y: maxY))
        p.addLine(to: CGPoint(x: maxX - arm, y: maxY))
        // bottom-left
        p.move(to: CGPoint(x: minX + arm, y: maxY))
        p.addLine(to: CGPoint(x: minX + r, y: maxY))
        p.addQuadCurve(to: CGPoint(x: minX, y: maxY - r), control: CGPoint(x: minX, y: maxY))
        p.addLine(to: CGPoint(x: minX, y: maxY - arm))
        return p
    }
}

private struct FaceIDFace: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        var p = Path()
        // eyes
        p.move(to: pt(0.34, 0.33)); p.addLine(to: pt(0.34, 0.42))
        p.move(to: pt(0.66, 0.33)); p.addLine(to: pt(0.66, 0.42))
        // nose
        p.move(to: pt(0.5, 0.34)); p.addLine(to: pt(0.5, 0.56)); p.addLine(to: pt(0.45, 0.56))
        // smile
        p.move(to: pt(0.34, 0.67))
        p.addQuadCurve(to: pt(0.66, 0.67), control: pt(0.5, 0.79))
        return p
    }
}

private struct FaceIDCheck: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + w * 0.3, y: rect.minY + h * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.45, y: rect.minY + h * 0.66))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.71, y: rect.minY + h * 0.36))
        return p
    }
}
