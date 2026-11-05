import SwiftUI

// Unified motion policy for the main island. Durations are paired with the
// transition coordinator in IslandState to prevent detached content/shape.
enum IslandMotion {
    // 4.8.0 — tuned to feel like iPhone's Dynamic Island: the shape moves
    // on a lively spring with a small overshoot, contents cross-fade
    // through a blur and a little scale.
    static let morph = Animation.spring(response: 0.46, dampingFraction: 0.74)
    // 4.12.3: shrinking back to the notch never overshoots — an underdamped
    // spring briefly made the island smaller than the camera cutout, and the
    // cutout (darker than any black the screen can show) peeked out.
    static let morphCollapse = Animation.spring(response: 0.42, dampingFraction: 1.0)
    static let content = Animation.easeInOut(duration: 0.28)
    static let canvasSettle: TimeInterval = 0.53
    static let eventHoldCharging: TimeInterval = 2.05
    static let eventHoldAirPods: TimeInterval = 5.0
    static let eventHoldLowBattery: TimeInterval = 7.0
    static let eventHoldFocus: TimeInterval = 2.4
    static let eventHoldUpdate: TimeInterval = 6.0
    static let eventHoldNotice: TimeInterval = 2.2
    static let eventSettle: TimeInterval = 0.56

    // 3.2.0 — one banner language for charging, battery, AirPods, Focus and
    // updates, matching the timer "drop": the black shape grows with a soft
    // spring, contents fade in from a light blur AFTER it, and on exit the
    // contents leave first, then the shape retracts without overshoot.
    static let banner = Animation.spring(response: 0.5, dampingFraction: 0.68)
    static let bannerRetract = Animation.spring(response: 0.42, dampingFraction: 1.0)
    static let bannerContentIn = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let bannerContentOut = Animation.easeIn(duration: 0.15)
    static let bannerContentDelay: TimeInterval = 0.13
    static let bannerExitLead: TimeInterval = 0.12
}
