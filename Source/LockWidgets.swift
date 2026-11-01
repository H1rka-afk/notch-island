import AppKit
import SwiftUI
import SystemConfiguration

// 3.7.1 — widgets under the clock on the lock screen, like on iPhone.
// Up to four glass tiles in a row; the user chooses which and in what order.
// Data comes only from what Notch Island already reads: battery, AirPods,
// Calendar/Reminders (when access was granted), the Clock timer, Focus.

enum LockWidgetKind: String, CaseIterable, Identifiable {
    case weather, battery, airpods, calendar, reminders, timer, focus
    case accessories, system, sun        // 3.12.0

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: return "Погода"
        case .battery: return "Батарея Mac"
        case .airpods: return "AirPods"
        case .calendar: return "Ближайшая встреча"
        case .reminders: return "Напоминания на сегодня"
        case .timer: return "Таймер"
        case .focus: return "Фокусирование"
        case .accessories: return "Мышь и клавиатура"
        case .system: return "Нагрузка Mac"
        case .sun: return "Восход и закат"
        }
    }

    var subtitle: String {
        switch self {
        case .weather: return "Температура и небо в твоём городе"
        case .battery: return "Заряд и зарядка"
        case .airpods: return "Когда подключены"
        case .calendar: return "Нужен доступ к Календарю"
        case .reminders: return "Нужен доступ к Напоминаниям"
        case .timer: return "Когда запущен"
        case .focus: return "Когда включён режим"
        case .accessories: return "Заряд Magic Mouse, Keyboard, Trackpad — когда подключены"
        case .system: return "Процессор и память, как в Мониторинге системы"
        case .sun: return "Ближайший восход или закат там, где ты"
        }
    }

    var symbol: String {
        switch self {
        case .weather: return "cloud.sun.fill"
        case .battery: return "battery.75percent"
        case .airpods: return "airpodspro"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .timer: return "timer"
        case .focus: return "moon.fill"
        case .accessories: return "computermouse.fill"
        case .system: return "cpu"
        case .sun: return "sunrise.fill"
        }
    }
}

struct LockWidgetItem: Identifiable, Equatable {
    let kind: LockWidgetKind
    var heading: String = ""   // small top line next to the symbol
    var symbol: String
    var value: String          // big line
    var caption: String        // small line
    var progress: Double?      // 0…1 bar, e.g. battery
    var tint: Color
    var id: String { kind.rawValue }
}

final class LockWidgetsModel: ObservableObject {
    static let shared = LockWidgetsModel()
    static let maxCount = 4

    @Published private(set) var enabled: Bool
    @Published private(set) var selected: [LockWidgetKind]
    @Published var items: [LockWidgetItem] = []
    // 3.7.6: size of the whole row, 60…100%.
    @Published private(set) var scale: Double =
        min(1, max(0.6, (UserDefaults.standard.object(forKey: "lockWidgetsScaleV376") as? Double) ?? 1))

    // 3.9.2: every widget has its own place, moved by dragging in the
    // lock-screen editor. Shift from its default spot in the row under the
    // clock, as shares of the screen size (fits any display).
    @Published private(set) var offsets: [String: CGPoint] = [:]
    private let offsetsKey = "lockWidgetsOffsetsV392"

    var hasCustomPlaces: Bool { offsets.values.contains { $0 != .zero } }

    func offset(for kind: LockWidgetKind) -> CGPoint { offsets[kind.rawValue] ?? .zero }

    func setOffset(_ value: CGPoint, for kind: LockWidgetKind, save: Bool = true) {
        offsets[kind.rawValue] = CGPoint(x: min(0.48, max(-0.48, value.x)), y: min(0.7, max(-0.24, value.y)))
        if save { saveOffsets() }
    }

    func resetOffsets() {
        offsets = [:]
        saveOffsets()
    }

    private func saveOffsets() {
        let plain = offsets.mapValues { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(plain, forKey: offsetsKey)
    }

    private func loadOffsets() {
        if let stored = UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: [Double]] {
            offsets = stored.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        } else {
            // 3.9.1 moved the whole row: start every widget from there.
            let x = UserDefaults.standard.double(forKey: "lockWidgetsOffsetXV391")
            let y = UserDefaults.standard.double(forKey: "lockWidgetsOffsetYV391")
            if x != 0 || y != 0 {
                for kind in LockWidgetKind.allCases { offsets[kind.rawValue] = CGPoint(x: x, y: y) }
            }
        }
    }

    func setScale(_ value: Double) {
        scale = min(1, max(0.6, value))
        UserDefaults.standard.set(scale, forKey: "lockWidgetsScaleV376")
    }

    private let enabledKey = "lockWidgetsEnabledV371"
    private let selectionKey = "lockWidgetsSelectionV371"

    private init() {
        enabled = (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
        let stored = UserDefaults.standard.stringArray(forKey: selectionKey)
        selected = (stored ?? ["battery", "calendar", "timer", "focus"]).compactMap(LockWidgetKind.init(rawValue:))
        loadOffsets()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    func isSelected(_ kind: LockWidgetKind) -> Bool { selected.contains(kind) }

    func toggle(_ kind: LockWidgetKind, on: Bool) {
        if on, !selected.contains(kind), selected.count < Self.maxCount { selected.append(kind) }
        if !on { selected.removeAll { $0 == kind } }
        save()
    }

    func move(_ kind: LockWidgetKind, by offset: Int) {
        guard let index = selected.firstIndex(of: kind) else { return }
        let target = index + offset
        guard selected.indices.contains(target) else { return }
        selected.swapAt(index, target)
        save()
    }

    private func save() {
        UserDefaults.standard.set(selected.map(\.rawValue), forKey: selectionKey)
    }

    // Items in the chosen order; kinds with nothing to show are skipped.
    func publish(_ available: [LockWidgetKind: LockWidgetItem]) {
        let ordered = selected.compactMap { available[$0] }
        if ordered != items { items = ordered }
    }
}

// MARK: - View

// 3.9.2: a full-screen canvas. Each widget stands at its own place: the
// default spot in the row under the clock plus its saved shift. In the
// editor every widget can be dragged on its own.
struct LockWidgetsView: View {
    @ObservedObject var model: LockWidgetsModel
    @ObservedObject var state: IslandState
    var editing = false
    @StateObject private var drag = WidgetDragModel()
    @ObservedObject private var activity = LockCoverActivity.widgets

    static let tile = CGSize(width: 190, height: 74)
    static let spacing: CGFloat = 26
    static let margin: CGFloat = 22
    static let rowTop: CGFloat = 0.255          // share of screen height

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let k = CGFloat(model.scale)
            // 3.16.3: nothing is drawn while the widgets window is hidden.
            let items = model.enabled && (editing || activity.active) ? model.items : []
            let tileW = Self.tile.width * k, tileH = Self.tile.height * k
            let gap = Self.spacing * k
            let rowW = CGFloat(items.count) * tileW + CGFloat(max(0, items.count - 1)) * gap
            let startX = (size.width - rowW) / 2
            let top = size.height * Self.rowTop
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let shift = model.offset(for: item.kind)
                    tile(item)
                        .scaleEffect(k)
                        .frame(width: tileW, height: tileH)
                        .overlay {
                            if editing {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(drag.active == item.kind ? 0.9 : 0.45),
                                                  style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                                    .padding(-8)
                            }
                        }
                        .contentShape(Rectangle().inset(by: -8))
                        .position(x: startX + CGFloat(index) * (tileW + gap) + tileW / 2 + shift.x * size.width,
                                  y: top + tileH / 2 + shift.y * size.height)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let origin = drag.begin(item.kind, from: shift)
                                model.setOffset(CGPoint(x: origin.x + value.translation.width / size.width,
                                                        y: origin.y + value.translation.height / size.height),
                                                for: item.kind, save: false)
                            }
                            .onEnded { _ in
                                model.setOffset(model.offset(for: item.kind), for: item.kind, save: true)
                                drag.end()
                            },
                            including: editing ? .all : .none)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: model.items.map(\.id))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(editing)
    }

    // 3.7.4: exactly the iPhone lock-screen layout (see the reference):
    //   line 1 — symbol + value, bold        («☁ 5°», «🎧 77 %»)
    //   line 2 — what it is, regular         («Облачно», «AirPods Pro»)
    //   line 3 — dim detail or a thick bar   («↓ 2° ↑ 10°», ▬▬▬▬▬▭▭)
    // No background; soft white with a light shadow.
    private func tile(_ item: LockWidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.tint == .white ? Color.white : item.tint)
                if item.kind == .timer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(ceil(state.timerRemaining(at: context.date))))
                        Text(seconds >= 3600
                             ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                             : String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .monospacedDigit()
                    }
                } else {
                    Text(item.value)
                }
            }
            .font(.system(size: 17, weight: .bold))

            if !item.heading.isEmpty {
                Text(item.heading)
                    .font(.system(size: 16, weight: .medium))
            }

            if let progress = item.progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.32))
                        Capsule()
                            .fill(LinearGradient(colors: [Color.white, Color.white.opacity(0.82)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geometry.size.width * CGFloat(min(1, max(0, progress)))))
                    }
                }
                .frame(width: 148, height: 9)
                .padding(.top, 4)
            } else if !item.caption.isEmpty {
                Text(item.caption)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white.opacity(0.95))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: Self.tile.width, height: Self.tile.height, alignment: .leading)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Building the items (pure formatting, data passed in)

enum LockWidgetBuilder {
    // 3.8.15: the Mac's own name, as set in System Settings → General →
    // About → Name (e.g. «MacBook Air»).
    static var macName: String {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? ""
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? "MacBook" : name
    }

    static func battery(_ power: PowerState?) -> LockWidgetItem? {
        guard let power else { return nil }
        let p = power.percentage
        let symbol: String
        if power.isCharging { symbol = "battery.100percent.bolt" }
        else if p > 87 { symbol = "battery.100percent" }
        else if p > 62 { symbol = "battery.75percent" }
        else if p > 37 { symbol = "battery.50percent" }
        else if p > 12 { symbol = "battery.25percent" }
        else { symbol = "battery.0percent" }
        let tint: Color = power.isCharging ? Color(red: 0.2, green: 0.85, blue: 0.4)
            : (p <= 10 ? Color(red: 1, green: 0.27, blue: 0.23)
               : (p <= 20 ? Color(red: 1, green: 0.8, blue: 0.0) : .white))
        return LockWidgetItem(kind: .battery, heading: power.isCharging ? "Заряжается" : macName,
                              symbol: symbol, value: "\(p) %", caption: "",
                              progress: Double(p) / 100, tint: tint)
    }

    static func airPods(_ status: AirPodsStatus?) -> LockWidgetItem? {
        guard let status else { return nil }
        let values = [status.left, status.right].compactMap { $0 }
        guard let level = values.min() ?? status.main else { return nil }
        return LockWidgetItem(kind: .airpods, heading: status.name.isEmpty ? "AirPods" : status.name,
                              symbol: "airpodspro", value: "\(level) %", caption: "",
                              progress: Double(level) / 100,
                              tint: level <= 20 ? Color(red: 1, green: 0.27, blue: 0.23) : .white)
    }

    static func calendar(_ event: (title: String, start: Date)?, now: Date = Date()) -> LockWidgetItem? {
        guard let event else {
            return LockWidgetItem(kind: .calendar, heading: "Встреч нет", symbol: "calendar", value: "Свободно",
                                  caption: "", progress: nil, tint: .white)
        }
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        let when: String
        if minutes <= 0 { when = "Сейчас" }
        else if minutes < 60 { when = "Через \(minutes) мин" }
        else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = Calendar.current.isDateInToday(event.start) ? "HH:mm" : "EE HH:mm"
            when = formatter.string(from: event.start)
        }
        return LockWidgetItem(kind: .calendar, heading: event.title, symbol: "calendar", value: when,
                              caption: "", progress: nil, tint: .white)
    }

    static func reminders(_ count: Int?) -> LockWidgetItem? {
        guard let count else { return nil }
        return LockWidgetItem(kind: .reminders, heading: count == 0 ? "Напоминания" : "Напоминаний",
                              symbol: count == 0 ? "checkmark.circle.fill" : "checklist",
                              value: count == 0 ? "Всё сделано" : "\(count)",
                              caption: count == 0 ? "" : "на сегодня",
                              progress: nil, tint: .white)
    }

    static func timer(active: Bool) -> LockWidgetItem? {
        guard active else { return nil }
        return LockWidgetItem(kind: .timer, heading: "Таймер", symbol: "timer", value: "",
                              caption: "", progress: nil, tint: .white)
    }

    static func focus(_ mode: FocusMode?, tint: Color) -> LockWidgetItem? {
        guard let mode else { return nil }
        return LockWidgetItem(kind: .focus, heading: "Фокусирование", symbol: mode.symbol, value: mode.name,
                              caption: "", progress: nil, tint: tint)
    }

    // 3.12.0: the accessory with the lowest charge (the one to charge first).
    static func accessories(_ list: [AccessoryBattery]) -> LockWidgetItem? {
        guard let low = list.first else { return nil }
        let red = Color(red: 1, green: 0.27, blue: 0.23)
        return LockWidgetItem(kind: .accessories, heading: AccessoryBattery.heading(list),
                              symbol: AccessoryBattery.symbol(for: low.name), value: "\(low.percent) %",
                              caption: "", progress: Double(low.percent) / 100,
                              tint: low.percent <= 15 ? red : .white)
    }

    static func system(_ load: SystemLoad) -> LockWidgetItem? {
        guard load.cpu != nil || load.memory != nil else { return nil }
        let hot = (load.cpu ?? 0) >= 0.85
        return LockWidgetItem(kind: .system, heading: "Память \(SystemLoad.percent(load.memory))",
                              symbol: "cpu", value: "ЦП \(SystemLoad.percent(load.cpu))", caption: "",
                              progress: load.cpu, tint: hot ? Color(red: 1, green: 0.58, blue: 0) : .white)
    }

    static func sun(_ snapshot: WeatherSnapshot?, now: Date = Date()) -> LockWidgetItem? {
        guard let snapshot, let next = WeatherCodes.nextSunEvent(snapshot, now: now) else { return nil }
        return LockWidgetItem(kind: .sun, heading: next.isSunrise ? "Восход" : "Закат",
                              symbol: next.isSunrise ? "sunrise.fill" : "sunset.fill",
                              value: SunFormat.time(next.time),
                              caption: next.dayLength.map(SunFormat.dayLength) ?? snapshot.place,
                              progress: nil, tint: Color(red: 1, green: 0.78, blue: 0.3))
    }

    static func weather(_ snapshot: WeatherSnapshot?, now: Date = Date()) -> LockWidgetItem? {
        guard let snapshot else { return nil }
        let hour = Calendar.current.component(.hour, from: now)
        let night = hour < 6 || hour >= 21
        var caption = snapshot.place
        if let high = snapshot.high, let low = snapshot.low { caption = "↓ \(low)° ↑ \(high)°" }
        return LockWidgetItem(kind: .weather, heading: WeatherCodes.text(snapshot.code),
                              symbol: WeatherCodes.symbol(snapshot.code, night: night),
                              value: "\(snapshot.temperature)°", caption: caption,
                              progress: nil, tint: .white)
    }
}


// Remembers where a dragged widget started (no @State — the command-line
// build has no SwiftUI macro plugin).
final class WidgetDragModel: ObservableObject {
    @Published private(set) var active: LockWidgetKind?
    private var origin: CGPoint = .zero

    func begin(_ kind: LockWidgetKind, from current: CGPoint) -> CGPoint {
        if active != kind {
            active = kind
            origin = current
        }
        return origin
    }

    func end() { active = nil }
}

// MARK: - 3.9.2 Lock-screen editor (preview on the desktop)

// Looks like the lock screen — wallpaper, date and clock, the player card's
// place — and stays until «Готово». Widgets are dragged one by one.
struct LockWidgetsEditor: View {
    @ObservedObject var model: LockWidgetsModel
    @ObservedObject var state: IslandState
    @ObservedObject private var display = SystemDisplayOptions.shared
    // 3.9.4: the wallpaper set on the Mac right now (may arrive a moment later).
    @ObservedObject var wallpaper: EditorWallpaper
    let onDone: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)],
                                   startPoint: .top, endPoint: .bottom)
                    if let image = wallpaper.image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.35), value: wallpaper.image)
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay(Color.black.opacity(0.18))

                TimelineView(.everyMinute) { context in
                    ZStack {
                        Text(LockCoverWallpaper.date(context.date))
                            .font(.system(size: size.height * 0.025, weight: .semibold))
                            .position(x: size.width / 2, y: size.height * 0.1056)
                        Text(LockCoverWallpaper.time(context.date))
                            .font(.system(size: size.height * 0.119, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .position(x: size.width / 2, y: size.height * 0.187)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                }

                // Where the player card stands, for reference.
                let k = CGFloat(display.cardScale)
                let card = CGSize(width: LockScreenMediaCard.size.width * k, height: LockScreenMediaCard.size.height * k)
                let cardBottom = max(190, size.height * 0.235)
                RoundedRectangle(cornerRadius: 36 * k, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 36 * k, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .overlay(Text("Медиаплеер").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6)))
                    .frame(width: card.width, height: card.height)
                    .position(x: size.width / 2, y: size.height - cardBottom - card.height / 2)

                LockWidgetsView(model: model, state: state, editing: true)

                VStack(spacing: 10) {
                    Text("Перетаскивай виджеты по одному")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    HStack(spacing: 10) {
                        Button("Сбросить") { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { model.resetOffsets() } }
                            .disabled(!model.hasCustomPlaces)
                        Button("Готово", action: onDone)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                }
                .position(x: size.width / 2, y: size.height * 0.93)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
