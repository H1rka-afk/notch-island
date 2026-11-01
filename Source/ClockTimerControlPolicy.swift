import Foundation

// An AXPress result means that a button accepted a press, NOT that the
// Clock timer has changed state. Never infer a toggle from that result.
enum ClockTimerControlPolicy {
    enum Button: Equatable { case pause, resume, cancel, unknown }

    static func button(for label: String) -> Button {
        let text = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown }
        let resume = ["resume", "continue", "возобнов", "продолжить", "продолжение"]
        let pause = ["pause", "приостанов", "пауза"]
        let cancel = ["cancel", "stop timer", "delete timer", "reset timer",
                      "отмен", "остановить таймер", "удалить таймер", "сброс таймера",
                      "close timer", "dismiss timer", "закрыть таймер"]
        let isResume = resume.contains(where: text.contains)
        let isPause = pause.contains(where: text.contains)
        let isCancel = cancel.contains(where: text.contains)
        // Composite accessibility descriptions such as "Pause / Resume"
        // do not identify which action the button would perform.
        guard [isResume, isPause, isCancel].filter({ $0 }).count == 1 else { return .unknown }
        if isResume { return .resume }
        if isPause { return .pause }
        return .cancel
    }

    // Regression: a saved duration (e.g. 05:00), a timer-related label, or
    // an unrelated Pause button must never create an active Clock timer.
    // A paused timer can persist only after the very same AX field was
    // validated by an earlier countdown and still has an associated control.
    static func acceptsTimerObservation(decremented: Bool,
                                        previouslyVerifiedSameField: Bool,
                                        associatedControl: Bool,
                                        action: Button) -> Bool {
        if decremented { return true }
        return previouslyVerifiedSameField && associatedControl &&
            (action == .pause || action == .resume)
    }

    static func confirmsToggle(expectedPaused: Bool, observedPaused: Bool?,
                               hasEvidence: Bool) -> Bool {
        hasEvidence && observedPaused == expectedPaused
    }

    // 4.3.1 — Clock's timer set-up screen: a Start button and no
    // Pause/Resume control anywhere. Seen right after a cancel (or when a
    // timer finished) in Clock itself; other tabs have no Start button.
    static func showsTimerSetup(labels: [String]) -> Bool {
        var start = false
        for label in labels {
            let text = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 24 else { continue }
            let action = button(for: text)
            if action == .pause || action == .resume { return false }
            if ["start", "старт", "начать", "запустить"].contains(text) { start = true }
        }
        return start
    }

    static func confirmsCancel(missingChecks: Int, reliableMissing: Bool) -> Bool {
        reliableMissing && missingChecks >= 2
    }

    static func observedPaused(button: Button, ticked: Bool,
                               stalled: Bool, previous: Bool?) -> Bool? {
        switch button {
        case .pause: return false
        case .resume: return true
        case .cancel, .unknown:
            if ticked { return false }
            if stalled { return true }
            return previous
        }
    }
}
