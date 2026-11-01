import Foundation

// Pure recogniser for media gestures on the island (Foundation only, tested).
// Input is in FINGER coordinates: +dx = fingers moved right, +dy = fingers
// moved up — the caller removes the "natural scrolling" inversion first.
//  • Two-finger swipe left  → next track, swipe right → previous track
//    (one action per gesture, like on iPhone).
//  • Vertical movement      → volume steps (fingers up = louder).
// The first clear direction locks the axis, so a swipe never changes the
// volume and a volume scroll never skips a track.
struct MediaScrollGesture {
    enum Action: Equatable {
        case next
        case previous
        case volume(steps: Int)
    }

    private enum Axis { case undecided, horizontal, vertical }

    var swipeThreshold = 42.0     // points of finger travel for a track change
    var volumeStepDistance = 11.0 // points of finger travel per volume step
    var axisDecisionDistance = 7.0

    private var axis: Axis = .undecided
    private var totalX = 0.0
    private var totalY = 0.0
    private var swipeFired = false
    private var volumeRemainder = 0.0

    mutating func reset() {
        axis = .undecided
        totalX = 0
        totalY = 0
        swipeFired = false
        volumeRemainder = 0
    }

    // Trackpad / Magic Mouse: continuous deltas inside one gesture.
    mutating func update(dx: Double, dy: Double) -> [Action] {
        totalX += dx
        totalY += dy
        if axis == .undecided {
            guard max(abs(totalX), abs(totalY)) >= axisDecisionDistance else { return [] }
            axis = abs(totalX) > abs(totalY) * 1.3 ? .horizontal : .vertical
            if axis == .vertical { volumeRemainder = totalY }
            else { volumeRemainder = 0 }
            return axis == .horizontal ? horizontalAction() : verticalActions(adding: 0)
        }
        return axis == .horizontal ? horizontalAction() : verticalActions(adding: dy)
    }

    // Classic mouse wheel: each notch is one volume step; no swipes.
    static func wheelAction(dy: Double) -> Action? {
        guard dy != 0 else { return nil }
        return .volume(steps: dy > 0 ? 1 : -1)
    }

    private mutating func horizontalAction() -> [Action] {
        guard !swipeFired, abs(totalX) >= swipeThreshold else { return [] }
        swipeFired = true
        return [totalX < 0 ? .next : .previous]
    }

    private mutating func verticalActions(adding dy: Double) -> [Action] {
        volumeRemainder += dy
        let steps = Int((volumeRemainder / volumeStepDistance).rounded(.towardZero))
        guard steps != 0 else { return [] }
        volumeRemainder -= Double(steps) * volumeStepDistance
        return [.volume(steps: steps)]
    }
}
