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
    var wide: Bool = true      // 4.6.0: wide tile or small round widget
    var id: String { kind.rawValue }

    // 4.6.0: shown in the editor when the widget has no data right now.
    static func placeholder(_ kind: LockWidgetKind) -> LockWidgetItem {
        LockWidgetItem(kind: kind, heading: kind.title, symbol: kind.symbol, value: "—",
                       caption: kind.subtitle, progress: nil, tint: .white)
    }
}

final class LockWidgetsModel: ObservableObject {
    static let shared = LockWidgetsModel()
    static let maxCount = LockWidgetLayoutMath.capacity

    @Published private(set) var enabled: Bool
    // 4.6.0: the row under the clock — four places, wide widgets take two.
    @Published private(set) var slots: [LockWidgetSlot]
    @Published var items: [LockWidgetItem] = []
    // Data of every widget (also those not on the screen) for the gallery.
    @Published private(set) var available: [LockWidgetKind: LockWidgetItem] = [:]
    // The lock-screen editor is open: the app reads data for all widgets.
    @Published var editing = false
    var requestRefresh: (() -> Void)?
    // 3.7.6: size of the whole row, 60…100%.
    @Published private(set) var scale: Double =
        min(1, max(0.6, (UserDefaults.standard.object(forKey: "lockWidgetsScaleV376") as? Double) ?? 1))

    var selected: [LockWidgetKind] { slots.compactMap { LockWidgetKind(rawValue: $0.kind) } }
    var freePlaces: Int { LockWidgetLayoutMath.free(slots) }

    func setScale(_ value: Double) {
        scale = min(1, max(0.6, value))
        UserDefaults.standard.set(scale, forKey: "lockWidgetsScaleV376")
    }

    private let enabledKey = "lockWidgetsEnabledV371"
    private let oldSelectionKey = "lockWidgetsSelectionV371"
    private let layoutKey = "lockWidgetsLayoutV460"
    private static let known = Set(LockWidgetKind.allCases.map(\.rawValue))

    private init() {
        enabled = (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
        if let stored = UserDefaults.standard.stringArray(forKey: layoutKey) {
            slots = LockWidgetLayoutMath.decode(stored, known: Self.known)
        } else {
            let old = UserDefaults.standard.stringArray(forKey: oldSelectionKey) ?? ["battery", "calendar", "timer", "focus"]
            slots = LockWidgetLayoutMath.migrate(old, known: Self.known)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    func isSelected(_ kind: LockWidgetKind) -> Bool { slots.contains { $0.kind == kind.rawValue } }
    func isWide(_ kind: LockWidgetKind) -> Bool { slots.first { $0.kind == kind.rawValue }?.wide ?? true }

    func add(_ kind: LockWidgetKind, wide: Bool = true, at index: Int? = nil) {
        apply(LockWidgetLayoutMath.adding(kind.rawValue, wide: wide, at: index, to: slots))
    }
    func remove(_ kind: LockWidgetKind) { apply(LockWidgetLayoutMath.removing(kind.rawValue, from: slots)) }
    func move(_ kind: LockWidgetKind, to index: Int) { apply(LockWidgetLayoutMath.moving(kind.rawValue, to: index, in: slots)) }
    func resize(_ kind: LockWidgetKind) { apply(LockWidgetLayoutMath.resizing(kind.rawValue, in: slots)) }

    private func apply(_ next: [LockWidgetSlot]) {
        guard next != slots else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            slots = next
            publish(available)
        }
        UserDefaults.standard.set(LockWidgetLayoutMath.encode(slots), forKey: layoutKey)
        requestRefresh?()
    }

    // Items in the chosen order and sizes; kinds with nothing to show are
    // skipped (on the lock screen) or shown as placeholders (in the editor).
    func publish(_ data: [LockWidgetKind: LockWidgetItem]) {
        if data != available { available = data }
        let ordered: [LockWidgetItem] = slots.compactMap { slot in
            guard let kind = LockWidgetKind(rawValue: slot.kind) else { return nil }
            guard var item = data[kind] ?? (editing ? LockWidgetItem.placeholder(kind) : nil) else { return nil }
            item.wide = slot.wide
            return item
        }
        if ordered != items { items = ordered }
    }
}

// MARK: - View

// 4.6.0: one centred row under the clock, as on iPhone: small round
// widgets take one place, wide ones two.
enum LockWidgetGeometry {
    static let unit: CGFloat = 86
    static let gap: CGFloat = 18
    static let height: CGFloat = 74
    static let rowTop: CGFloat = 0.255          // share of screen height

    static func width(wide: Bool) -> CGFloat { wide ? unit * 2 + gap : unit }

    static func rowWidth(_ items: [LockWidgetItem]) -> CGFloat {
        let units = items.reduce(0) { $0 + ($1.wide ? 2 : 1) }
        return CGFloat(units) * unit + CGFloat(max(0, units - 1)) * gap
    }

    // Centre x of item `index`, relative to the row's left edge.
    static func centre(of index: Int, in items: [LockWidgetItem]) -> CGFloat {
        var x: CGFloat = 0
        for i in 0..<index { x += width(wide: items[i].wide) + gap }
        return x + width(wide: items[index].wide) / 2
    }
}

struct LockWidgetsView: View {
    @ObservedObject var model: LockWidgetsModel
    @ObservedObject var state: IslandState
    @ObservedObject private var activity = LockCoverActivity.widgets

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let k = CGFloat(model.scale)
            // 3.16.3: nothing is drawn while the widgets window is hidden.
            let items = model.enabled && activity.active ? model.items : []
            let rowW = LockWidgetGeometry.rowWidth(items) * k
            let startX = (size.width - rowW) / 2
            let top = size.height * LockWidgetGeometry.rowTop
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    LockWidgetTile(item: item, state: state)
                        .scaleEffect(k)
                        .frame(width: LockWidgetGeometry.width(wide: item.wide) * k,
                               height: LockWidgetGeometry.height * k)
                        .position(x: startX + LockWidgetGeometry.centre(of: index, in: items) * k,
                                  y: top + LockWidgetGeometry.height * k / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: model.items.map { $0.id + ($0.wide ? "w" : "s") })
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

// One widget: the wide iPhone layout, or the small round one.
struct LockWidgetTile: View {
    let item: LockWidgetItem
    @ObservedObject var state: IslandState

    var body: some View {
        Group {
            if item.wide { wide } else { small }
        }
        .foregroundStyle(.white.opacity(0.95))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var valueText: some View {
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

    private var symbolTint: Color { item.tint == .white ? Color.white : item.tint }

    // 3.7.4: exactly the iPhone lock-screen layout (see the reference):
    //   line 1 — symbol + value, bold        («☁ 5°», «🎧 77 %»)
    //   line 2 — what it is, regular         («Облачно», «AirPods Pro»)
    //   line 3 — dim detail or a thick bar   («↓ 2° ↑ 10°», ▬▬▬▬▬▭▭)
    private var wide: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(symbolTint)
                valueText
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
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: LockWidgetGeometry.width(wide: true), height: LockWidgetGeometry.height, alignment: .leading)
    }

    // 4.6.0: iPhone's small round widget — a soft glass circle, a ring
    // when there is a level (battery), the symbol and the value inside.
    private var small: some View {
        let d: CGFloat = 70
        return ZStack {
            Circle().fill(Color.white.opacity(0.14))
            if let progress = item.progress {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 5)
                    .padding(4)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0.02, progress))))
                    .stroke(symbolTint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
            }
            VStack(spacing: 1) {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(symbolTint)
                    .font(.system(size: 17, weight: .semibold))
                valueText
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 8)
            }
        }
        .frame(width: d, height: d)
        .frame(width: LockWidgetGeometry.width(wide: false), height: LockWidgetGeometry.height)
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


// 4.6.0 — dragging a widget in the editor (from the gallery or along the
// row). No @State: the command-line build has no SwiftUI macro plugin.
final class WidgetDragModel: ObservableObject {
    @Published var kind: LockWidgetKind?
    @Published var location: CGPoint = .zero
    @Published var fromGallery = false
    @Published var galleryOpen = false
}

// MARK: - 4.6.0 Lock-screen editor, like on iPhone

// Looks like the lock screen — wallpaper, date and clock. Under the clock
// the row of four places: every widget has «−» to remove it and a size
// button (small ↔ wide); drag a widget along the row to reorder. «+»
// (or a free place) opens the gallery at the bottom with live previews:
// click a widget to add it, or drag it into the row.
struct LockWidgetsEditor: View {
    @ObservedObject var model: LockWidgetsModel
    @ObservedObject var state: IslandState
    @ObservedObject private var display = SystemDisplayOptions.shared
    // 3.9.4: the wallpaper set on the Mac right now (may arrive a moment later).
    @ObservedObject var wallpaper: EditorWallpaper
    let onDone: () -> Void
    @StateObject private var drag = WidgetDragModel()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let k = CGFloat(model.scale)
            let items = model.items
            let rowW = max(LockWidgetGeometry.rowWidth(items) * k, LockWidgetGeometry.unit * k)
            let rowLeft = (size.width - rowW) / 2
            let top = size.height * LockWidgetGeometry.rowTop
            let rowFrame = CGRect(x: (size.width - (LockWidgetGeometry.unit * 4 + LockWidgetGeometry.gap * 3) * k) / 2 - 20,
                                  y: top - 24,
                                  width: (LockWidgetGeometry.unit * 4 + LockWidgetGeometry.gap * 3) * k + 40,
                                  height: LockWidgetGeometry.height * k + 48)
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

                // The frame of the row, like iPhone's widget box in edit mode.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(drag.kind != nil && rowFrame.contains(drag.location) ? 0.16 : 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                    .frame(width: rowFrame.width, height: rowFrame.height)
                    .position(x: rowFrame.midX, y: rowFrame.midY)
                    .onTapGesture { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { drag.galleryOpen = true } }

                // Widgets in the row.
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let centre = CGPoint(x: rowLeft + LockWidgetGeometry.centre(of: index, in: items) * k,
                                         y: top + LockWidgetGeometry.height * k / 2)
                    let dragging = drag.kind == item.kind && !drag.fromGallery
                    LockWidgetTile(item: item, state: state)
                        .scaleEffect(k)
                        .frame(width: LockWidgetGeometry.width(wide: item.wide) * k, height: LockWidgetGeometry.height * k)
                        .overlay(alignment: .topLeading) {
                            Button { model.remove(item.kind) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 20))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color(white: 0.35))
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .offset(x: -10, y: -12)
                            .help("Убрать")
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Button { model.resize(item.kind) } label: {
                                Image(systemName: item.wide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(5)
                                    .background(Circle().fill(Color(white: 0.3)))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: 8)
                            .opacity(item.wide || model.freePlaces >= 1 ? 1 : 0.35)
                            .disabled(!item.wide && model.freePlaces < 1)
                            .help(item.wide ? "Сделать маленьким" : "Сделать широким")
                        }
                        .opacity(dragging ? 0.35 : 1)
                        .position(centre)
                        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("editor"))
                            .onChanged { value in
                                drag.kind = item.kind
                                drag.fromGallery = false
                                drag.location = value.location
                            }
                            .onEnded { value in
                                let x = Double((value.location.x - rowLeft) / max(1, rowW))
                                let others = model.slots.filter { $0.kind != item.kind.rawValue }
                                let index = LockWidgetLayoutMath.insertionIndex(x: x, in: others)
                                model.move(item.kind, to: index)
                                drag.kind = nil
                            })
                }

                // Free places: a «+» like iPhone.
                if model.freePlaces > 0 && items.count == model.slots.count {
                    let plusX = items.isEmpty ? size.width / 2 : rowLeft + rowW + LockWidgetGeometry.gap * k + 20 * k
                    Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { drag.galleryOpen = true } } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .position(x: min(plusX, rowFrame.maxX - 26), y: top + LockWidgetGeometry.height * k / 2)
                    .help("Добавить виджет")
                }

                // The widget being dragged follows the pointer.
                if let kind = drag.kind {
                    let item = model.available[kind] ?? LockWidgetItem.placeholder(kind)
                    let wide = drag.fromGallery ? model.freePlaces >= 2 : model.isWide(kind)
                    LockWidgetTile(item: { var i = item; i.wide = wide; return i }(), state: state)
                        .scaleEffect(k * 1.06)
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                        .position(drag.location)
                        .allowsHitTesting(false)
                }

                // Top: what to do and «Готово».
                VStack(spacing: 10) {
                    Text(model.slots.isEmpty
                         ? "Нажми «+», чтобы добавить виджеты"
                         : "«−» убрать · стрелки — размер · перетаскивай, чтобы поменять порядок")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    HStack(spacing: 10) {
                        Button("Добавить виджет") {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { drag.galleryOpen = true }
                        }
                        .disabled(model.freePlaces == 0)
                        Button("Готово", action: onDone)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                }
                .position(x: size.width / 2, y: drag.galleryOpen ? size.height * 0.5 : size.height * 0.93)

                // The gallery slides up from the bottom.
                if drag.galleryOpen {
                    gallery(size: size, rowFrame: rowFrame, rowLeft: rowLeft, rowW: rowW)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "editor")
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onAppear { model.editing = true; model.requestRefresh?() }
        .onDisappear { model.editing = false; model.requestRefresh?() }
    }

    private func gallery(size: CGSize, rowFrame: CGRect, rowLeft: CGFloat, rowW: CGFloat) -> some View {
        let height = min(360, size.height * 0.4)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Добавить виджеты")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Text(model.freePlaces == 0 ? "Места нет — убери или уменьши виджет"
                     : "Свободно мест: \(model.freePlaces) из 4")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { drag.galleryOpen = false } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(LockWidgetKind.allCases) { kind in
                        galleryCard(kind, rowFrame: rowFrame, rowLeft: rowLeft, rowW: rowW)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(width: min(size.width - 80, 1100), height: height)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .position(x: size.width / 2, y: size.height - height / 2 - 30)
    }

    private func galleryCard(_ kind: LockWidgetKind, rowFrame: CGRect, rowLeft: CGFloat, rowW: CGFloat) -> some View {
        let added = model.isSelected(kind)
        let item = model.available[kind] ?? LockWidgetItem.placeholder(kind)
        let canWide = model.freePlaces >= 2, canSmall = model.freePlaces >= 1
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07))
                HStack(spacing: 10) {
                    LockWidgetTile(item: { var i = item; i.wide = false; return i }(), state: state)
                        .scaleEffect(0.8)
                        .frame(width: 70, height: 62)
                    LockWidgetTile(item: { var i = item; i.wide = true; return i }(), state: state)
                        .scaleEffect(0.8)
                        .frame(width: 155, height: 62)
                }
            }
            .frame(width: 250, height: 96)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("editor"))
                .onChanged { value in
                    guard !added, canSmall else { return }
                    drag.kind = kind
                    drag.fromGallery = true
                    drag.location = value.location
                }
                .onEnded { value in
                    defer { drag.kind = nil }
                    guard !added, canSmall, rowFrame.contains(value.location) else { return }
                    let x = Double((value.location.x - rowLeft) / max(1, rowW))
                    model.add(kind, wide: canWide, at: LockWidgetLayoutMath.insertionIndex(x: x, in: model.slots))
                })
            Text(kind.title).font(.system(size: 13, weight: .semibold))
            Text(kind.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                .frame(width: 250, alignment: .leading)
            HStack(spacing: 8) {
                if added {
                    Label("На экране", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.green)
                    Button("Убрать") { model.remove(kind) }
                } else {
                    Button("Маленький") { model.add(kind, wide: false) }.disabled(!canSmall)
                    Button("Широкий") { model.add(kind, wide: true) }.disabled(!canWide)
                }
            }
            .controlSize(.small)
        }
        .frame(width: 250, alignment: .topLeading)
    }
}
