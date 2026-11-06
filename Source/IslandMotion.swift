import SwiftUI

// Unified motion policy for the main island. Durations are paired with the
// transition coordinator in IslandState to prevent detached content/shape.
enum IslandMotion {
    // 4.8.0 — tuned to feel like iPhone's Dynamic Island: the shape moves
    // on a lively spring with a small overshoot, contents cross-fade
    // through a blur and a little scale.
    // 4.13.2 — ONE motion language for everything at the notch and on the
    // lock screen:
    //   grow    — a black shape appears or gets bigger (island, banner,
    //             timer, shelf): lively, a small overshoot outwards;
    //   shrink  — it gets smaller or goes back into the notch: no overshoot;
    //   surface — cards, menus and panels opening or moving: calm;
    //   press   — a tap or a nudge: short and springy.
    static let grow = Animation.spring(response: 0.48, dampingFraction: 0.76)
    static let shrink = Animation.spring(response: 0.42, dampingFraction: 1.0)
    static let surface = Animation.spring(response: 0.45, dampingFraction: 0.86)
    static let press = Animation.spring(response: 0.26, dampingFraction: 0.58)

    static let morph = grow
    // 4.12.3: shrinking back to the notch never overshoots — an underdamped
    // spring briefly made the island smaller than the camera cutout, and the
    // cutout (darker than any black the screen can show) peeked out.
    static let morphCollapse = shrink
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
    static let banner = grow
    static let bannerRetract = shrink
    static let bannerContentIn = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let bannerContentOut = Animation.easeIn(duration: 0.15)
    static let bannerContentDelay: TimeInterval = 0.13
    static let bannerExitLead: TimeInterval = 0.12
}
