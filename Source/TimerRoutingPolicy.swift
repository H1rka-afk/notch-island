// Pure timer routing logic: macOS windows must never show two persistent
// copies of the same countdown. Kept Foundation-free for regression tests.
enum TimerRoutingPolicy {
    static func showsSatellite(timer: Bool, preview: Bool, music: Bool,
                               event: Bool, locked: Bool, unlocking: Bool) -> Bool {
        guard !locked && !unlocking else { return false }
        return (timer || preview) && (music || event)
    }

    // Media + a detached timer share a fixed, maximum-size media canvas.
    // The canvas's right edge coincides with the compact music right edge,
    // so changing the shape's width never relocates its NSPanel.
    static func fixedMediaCanvasLeft(notchCenter: Double, notchWidth: Double,
                                     mediaWing: Double, canvasWidth: Double) -> Double {
        notchCenter + notchWidth / 2 + mediaWing - canvasWidth
    }

    // Keep an asymmetric timer-only island centred in the exact same place
    // during the compact -> expanded -> compact sequence. Geometry is pure
    // so it can be tested without macOS/AppKit.
    static func expandedTimerLeft(notchCenter: Double, notchWidth: Double,
                                  leftWing: Double, rightWing: Double,
                                  expandedWidth: Double) -> Double {
        let compactLeft = notchCenter - notchWidth / 2 - leftWing
        let compactWidth = notchWidth + leftWing + rightWing
        return compactLeft + (compactWidth - expandedWidth) / 2
    }
}

// A verified Clock observation can be displayed between Accessibility scans.
// The system owns the timer; this is only visual interpolation. A failed AX
// poll must not erase an already verified timer immediately; however, stale
// UI state must expire if macOS no longer confirms the timer.
enum TimerObservationContinuity {
    static func remaining(last: Double, paused: Bool, secondsSinceObservation: Double) -> Double {
        max(0, last - (paused ? 0 : max(0, secondsSinceObservation)))
    }
    static func shouldRetain(last: Double, paused: Bool, secondsSinceObservation: Double) -> Bool {
        secondsSinceObservation >= 0 && secondsSinceObservation <= 45 &&
            (paused || remaining(last: last, paused: false,
                                 secondsSinceObservation: secondsSinceObservation) > 0)
    }
}
