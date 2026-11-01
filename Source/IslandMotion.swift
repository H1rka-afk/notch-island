import SwiftUI

// Unified motion policy for the main island. Durations are paired with the
// transition coordinator in IslandState to prevent detached content/shape.
enum IslandMotion {
    static let morph = Animation.spring(response: 0.43, dampingFraction: 0.88)
    static let content = Animation.easeInOut(duration: 0.25)
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
    static let banner = Animation.spring(response: 0.5, dampingFraction: 0.72)
    static let bannerRetract = Animation.spring(response: 0.42, dampingFraction: 0.92)
    static let bannerContentIn = Animation.easeOut(duration: 0.26)
    static let bannerContentOut = Animation.easeIn(duration: 0.14)
    static let bannerContentDelay: TimeInterval = 0.13
    static let bannerExitLead: TimeInterval = 0.12
}
