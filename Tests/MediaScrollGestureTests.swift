import Foundation

// swiftc -parse-as-library Source/MediaScrollGesture.swift Tests/MediaScrollGestureTests.swift -o g-tests && ./g-tests
@main
struct MediaScrollGestureTests {
    static func feed(_ deltas: [(Double, Double)]) -> [MediaScrollGesture.Action] {
        var gesture = MediaScrollGesture()
        gesture.reset()
        return deltas.flatMap { gesture.update(dx: $0.0, dy: $0.1) }
    }

    static func main() {
        // Swipe left (fingers move left) → exactly one "next", however long.
        let left = feed(Array(repeating: (-6.0, 0.4), count: 30))
        precondition(left == [.next], "left swipe: \(left)")
        // Swipe right → one "previous".
        precondition(feed(Array(repeating: (5.0, -0.3), count: 20)) == [.previous])
        // Too short a swipe does nothing.
        precondition(feed(Array(repeating: (-4.0, 0), count: 5)).isEmpty)

        // Fingers up → volume up; total 44 pt = 4 steps of 11 pt.
        let up = feed(Array(repeating: (0.2, 4.0), count: 11))
        precondition(up.reduce(0) { total, action in
            if case .volume(let steps) = action { return total + steps }
            return total
        } == 4, "volume up: \(up)")
        // Fingers down → volume down.
        let down = feed(Array(repeating: (0, -5.5), count: 4))
        precondition(down.allSatisfy { if case .volume(let s) = $0 { return s < 0 }; return false })
        precondition(!down.isEmpty)

        // Axis lock: a vertical gesture that later drifts sideways never skips.
        let drift = feed(Array(repeating: (0, 3.0), count: 5) + Array(repeating: (-9.0, 0), count: 10))
        precondition(!drift.contains(.next) && !drift.contains(.previous), "drift: \(drift)")
        // …and a horizontal swipe that wobbles vertically never changes volume.
        let wobble = feed(Array(repeating: (-8.0, 2.0), count: 8) + Array(repeating: (0, 6.0), count: 6))
        precondition(wobble == [.next], "wobble: \(wobble)")

        // Mouse wheel notches.
        precondition(MediaScrollGesture.wheelAction(dy: 1) == .volume(steps: 1))
        precondition(MediaScrollGesture.wheelAction(dy: -3) == .volume(steps: -1))
        precondition(MediaScrollGesture.wheelAction(dy: 0) == nil)

        print("MediaScrollGestureTests: OK")
    }
}
