import AppKit
import EventKit
import Foundation

// 3.3.0 (experimental): upcoming meetings (Calendar) and due reminders.
// Read-only; macOS asks for access the first time a switch is turned on.
final class AgendaWatch {
    var onMeeting: ((_ title: String, _ minutes: Int, _ link: URL?) -> Void)?
    var onReminder: ((_ title: String) -> Void)?
    var calendarEnabled = false
    var remindersEnabled = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced = Set<String>()

    static func hasAccess(to type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type) == .fullAccess
    }

    func requestAccess(to type: EKEntityType, completion: @escaping (Bool) -> Void) {
        let done: (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
        if type == .event { store.requestFullAccessToEvents(completion: done) }
        else { store.requestFullAccessToReminders(completion: done) }
    }

    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    // 3.7.1 lock-screen widgets: next timed event within a day.
    func nextEvent(withinHours hours: Double = 24) -> (title: String, start: Date)? {
        guard Self.hasAccess(to: .event) else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60),
                                                 end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && ($0.endDate ?? now) > now && $0.startDate != nil }
            .sorted { $0.startDate < $1.startDate }
            .first
            .map { ($0.title ?? "Встреча", $0.startDate) }
    }

    // Incomplete reminders due by the end of today (overdue included).
    func remindersDueToday(_ completion: @escaping (Int?) -> Void) {
        guard Self.hasAccess(to: .reminder) else { completion(nil); return }
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        store.fetchReminders(matching: predicate) { reminders in
            let count = reminders?.count ?? 0
            DispatchQueue.main.async { completion(count) }
        }
    }

    private func tick() {
        let now = Date()
        if calendarEnabled && Self.hasAccess(to: .event) {
            let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(11 * 60), calendars: nil)
            for event in store.events(matching: predicate) where !event.isAllDay {
                guard let start = event.startDate, start > now else { continue }
                let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
                let key = "\(event.eventIdentifier ?? "")|\(start.timeIntervalSince1970)"
                guard minutes <= 10, !announced.contains(key) else { continue }
                announced.insert(key)
                onMeeting?(event.title ?? "Встреча", minutes, Self.meetingLink(event))
            }
        }
        if remindersEnabled && Self.hasAccess(to: .reminder) {
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: now.addingTimeInterval(-60), ending: now.addingTimeInterval(30), calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] reminders in
                let due = (reminders ?? []).map { ($0.calendarItemIdentifier, $0.title ?? "Напоминание") }
                DispatchQueue.main.async {
                    guard let self else { return }
                    for (identifier, title) in due where !self.announced.contains(identifier) {
                        self.announced.insert(identifier)
                        self.onReminder?(title)
                    }
                }
            }
        }
    }

    // Zoom, Telemost, Google Meet, Teams, Webex — from the URL field, the
    // location or the notes.
    static func meetingLink(_ event: EKEvent) -> URL? {
        if let url = event.url, url.scheme?.hasPrefix("http") == true { return url }
        let text = [event.location ?? "", event.notes ?? ""].joined(separator: " ")
        let pattern = #"https?://[^\s<>"]*(zoom\.us|telemost\.yandex|meet\.google|teams\.microsoft|webex\.com)[^\s<>"]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}
