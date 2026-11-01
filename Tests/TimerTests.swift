import Foundation

@main struct TimerTests {
    static func main() {
        let cases: [(String, Int?)] = [
            ("05:09",309), ("1:02:33",3753), ("90:00",5400),
            ("2 мин 30 сек",150), ("2m 15s",135),
            ("1 час 05 мин 23 сек",3923),
            ("3 hours 2 minutes 4 seconds",10924),
            ("5 minutes",nil), ("10:75",nil), ("00:00",0)
        ]
        for (text, value) in cases {
            let result = ClockTimerTextParser.remaining(in:text).map(Int.init)
            precondition(result == value, "Parser \(text): got \(String(describing: result)), wanted \(String(describing:value))")
        }
        let digits: [([String], Int?)] = [
            (["09", "58"], 598), (["1", ":", "05", ":", "09"], 3909),
            (["09", ":", "58"], 598), (["5", "min"], nil),
            (["10", "70"], nil), (["1", "2", "3", "4"], nil)
        ]
        for (parts, expected) in digits {
            let actual = ClockTimerTextParser.remainingFromDigitSiblings(parts).map(Int.init)
            precondition(actual == expected, "Digit siblings \(parts): \(String(describing: actual))")
        }
        precondition(ClockTimerTextParser.remaining(in: "09 : 58") == 598)
        func side(_ timer:Bool,_ preview:Bool,_ music:Bool,_ event:Bool,_ locked:Bool = false,_ unlocking:Bool = false)->Bool {
            TimerRoutingPolicy.showsSatellite(timer:timer,preview:preview,music:music,event:event,locked:locked,unlocking:unlocking)
        }
        precondition(!side(false,false,false,false))
        precondition(!side(true,false,false,false))
        precondition(side(true,false,true,false))
        precondition(side(true,false,false,true))
        precondition(!side(false,true,false,false))
        precondition(side(false,true,true,false))
        precondition(side(false,true,false,true))
        precondition(!side(false,true,true,false,true))
        precondition(!side(true,false,true,false,true))
        precondition(!side(true,false,true,false,false,true))
        precondition(!side(false,false,true,false))
        // Verify that expanding only a timer preserves the compact visible
        // centre, while still working on different notch sizes.
        for (notch, left, right, expanded) in [
            (194.0, 0.0, 86.0, 410.0),
            (210.0, 0.0, 86.0, 410.0),
            (194.0, 35.0, 35.0, 410.0),
            (280.0, 0.0, 86.0, 468.0)
        ] {
            let centre = 740.0
            let compactLeft = centre - notch / 2 - left
            let expectedCenter = compactLeft + (notch + left + right) / 2
            let expandedLeft = TimerRoutingPolicy.expandedTimerLeft(
                notchCenter: centre, notchWidth: notch,
                leftWing: left, rightWing: right, expandedWidth: expanded)
            precondition(abs(expandedLeft + expanded / 2 - expectedCenter) < 0.001)
        }
        // Regression from the 2026-10-29 two-island recording: the primary
        // NSPanel must NEVER jump horizontally on compact <-> expanded hover.
        // Check both widths on different physical cutouts.
        for (notch, wing, expanded) in [
            (194.0, 35.0, 410.0), (210.0, 35.0, 410.0),
            (280.0, 35.0, 468.0), (194.0, 35.0, 454.0)
        ] {
            let centre = 740.0
            let left = TimerRoutingPolicy.fixedMediaCanvasLeft(
                notchCenter: centre, notchWidth: notch,
                mediaWing: wing, canvasWidth: expanded)
            let compactWidth = notch + wing * 2
            let compactVisibleLeft = left + expanded - compactWidth
            let compactExpectedLeft = centre - notch / 2 - wing
            precondition(abs(compactVisibleLeft - compactExpectedLeft) < 0.001,
                         "Compact music must stay aligned with the physical notch")
            let expandedRight = left + expanded
            let compactRight = compactExpectedLeft + compactWidth
            precondition(abs(expandedRight - compactRight) < 0.001,
                         "Both silhouettes must share exactly the same right edge")
            let timerX = compactRight + 19.0
            precondition(expandedRight + 19 <= timerX + 0.001,
                         "Expanded media must not overlap the Clock satellite")
        }
        let decrementCases: [(Double, Double, Double, Bool)] = [
            (300, 290, 10, true), // five-minute Clock countdown
            (290, 280, 10, true),
            (300, 300, 10, false), // stationary preset
            (300, 310, 10, false), // advancing stopwatch
            (300, 290, 1, false), // unrelated number, wrong rate
            (300, 290, 60, false), // stale sample
            (10, 0, 10, true)
        ]
        for (previous, current, elapsed, expected) in decrementCases {
            precondition(ClockTimerTextParser.isDecreasingCountdown(
                previous: previous, current: current, elapsed: elapsed) == expected)
        }
        // Verified snapshots survive missed AX reads but not their actual
        // deadline. Pause holds the display; resume uses the real elapsed time.
        for (last, paused, age, expected) in [
            (217.0, false, 0.0, 217.0),
            (217.0, false, 1.0, 216.0),
            (217.0, false, 30.0, 187.0),
            (5.0, false, 9.0, 0.0),
            (5.0, true, 99.0, 5.0),
            (10.0, false, -4.0, 10.0)
        ] {
            precondition(abs(TimerObservationContinuity.remaining(
                last: last, paused: paused, secondsSinceObservation: age) - expected) < 0.001)
        }
        precondition(TimerObservationContinuity.shouldRetain(last: 217, paused: false, secondsSinceObservation: 30))
        precondition(!TimerObservationContinuity.shouldRetain(last: 217, paused: false, secondsSinceObservation: 60))
        precondition(!TimerObservationContinuity.shouldRetain(last: 5, paused: false, secondsSinceObservation: 6))
        precondition(TimerObservationContinuity.shouldRetain(last: 5, paused: true, secondsSinceObservation: 30))
        precondition(!TimerObservationContinuity.shouldRetain(last: 5, paused: true, secondsSinceObservation: 999))
        // False-positive regression: the selected 05:00 template is NOT an
        // active timer, even with timer text or unrelated playback controls.
        precondition(!ClockTimerControlPolicy.acceptsTimerObservation(
            decremented: false, previouslyVerifiedSameField: false,
            associatedControl: true, action: .pause))
        precondition(!ClockTimerControlPolicy.acceptsTimerObservation(
            decremented: false, previouslyVerifiedSameField: false,
            associatedControl: false, action: .resume))
        precondition(ClockTimerControlPolicy.acceptsTimerObservation(
            decremented: true, previouslyVerifiedSameField: false,
            associatedControl: false, action: .unknown))
        precondition(ClockTimerControlPolicy.acceptsTimerObservation(
            decremented: false, previouslyVerifiedSameField: true,
            associatedControl: true, action: .resume))
        precondition(!ClockTimerControlPolicy.acceptsTimerObservation(
            decremented: false, previouslyVerifiedSameField: true,
            associatedControl: false, action: .unknown))
        // A successful AXPress never itself validates an updated timer.
        precondition(ClockTimerControlPolicy.button(for: "Pause Timer") == .pause)
        precondition(ClockTimerControlPolicy.button(for: "Продолжить таймер") == .resume)
        precondition(ClockTimerControlPolicy.button(for: "Отмена") == .cancel)
        precondition(ClockTimerControlPolicy.button(for: "Reset Timer") == .cancel)
        precondition(ClockTimerControlPolicy.button(for: "Pause / Resume") == .unknown)
        precondition(ClockTimerControlPolicy.button(for: "Clock") == .unknown)
        precondition(ClockTimerControlPolicy.observedPaused(button: .pause, ticked: false, stalled: false, previous: true) == false)
        precondition(ClockTimerControlPolicy.observedPaused(button: .resume, ticked: true, stalled: false, previous: false) == true)
        precondition(ClockTimerControlPolicy.observedPaused(button: .unknown, ticked: true, stalled: false, previous: true) == false)
        precondition(ClockTimerControlPolicy.observedPaused(button: .unknown, ticked: false, stalled: true, previous: false) == true)
        precondition(ClockTimerControlPolicy.observedPaused(button: .unknown, ticked: false, stalled: false, previous: true) == true)
        precondition(!ClockTimerControlPolicy.confirmsToggle(expectedPaused: true, observedPaused: true, hasEvidence: false))
        precondition(!ClockTimerControlPolicy.confirmsToggle(expectedPaused: true, observedPaused: false, hasEvidence: true))
        precondition(ClockTimerControlPolicy.confirmsToggle(expectedPaused: true, observedPaused: true, hasEvidence: true))
        precondition(!ClockTimerControlPolicy.confirmsCancel(missingChecks: 1, reliableMissing: true))
        precondition(!ClockTimerControlPolicy.confirmsCancel(missingChecks: 3, reliableMissing: false))
        precondition(ClockTimerControlPolicy.confirmsCancel(missingChecks: 2, reliableMissing: true))
        print("PASS timer parsing/routing/geometry/continuity/control confirmation")
    }
}
