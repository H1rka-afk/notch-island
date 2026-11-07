import AppKit
import SwiftUI

// 5.0.0 — live activities, like on iPhone: a taxi ride or a food / grocery
// order stays in the island from the first notification to the last,
// with its stage, a progress bar and the minutes left. Ovira builds it
// from the same notifications as the delivery banners (4.16.0): every new
// one moves the activity forward. Parcels stay ordinary banners — they
// take days, not minutes.
struct LiveActivity: Equatable {
    enum Kind { case taxi, order }

    let id: String                 // the service («Яндекс Go»)
    let kind: Kind
    var name: String
    var symbol: String
    var tint: Color
    var icon: NSImage?
    var stage: Int
    var status: String             // the latest notification line
    var etaDate: Date?
    var finished = false
    var started = Date()
    var updated = Date()

    var stages: [String] { LiveActivityParser.stages(kind) }
    var progress: Double {
        finished ? 1 : min(0.94, (Double(stage) + 0.5) / Double(max(1, stages.count)))
    }
    var stageTitle: String { stages[min(stage, stages.count - 1)] }

    func minutesLeft(now: Date = Date()) -> Int? {
        guard let etaDate, !finished else { return nil }
        return max(0, Int(ceil(etaDate.timeIntervalSince(now) / 60)))
    }

    // Short text for the closed island: «4 мин», else the stage.
    func shortText(now: Date = Date()) -> String {
        if finished { return kind == .taxi ? "Приехали" : "Готово" }
        if let m = minutesLeft(now: now) { return m == 0 ? "Сейчас" : "\(m) мин" }
        return stageTitle
    }

    static func == (a: LiveActivity, b: LiveActivity) -> Bool {
        a.id == b.id && a.stage == b.stage && a.status == b.status && a.etaDate == b.etaDate &&
            a.finished == b.finished && (a.icon == nil) == (b.icon == nil)
    }
}

enum LiveActivityParser {
    static func stages(_ kind: LiveActivity.Kind) -> [String] {
        switch kind {
        case .taxi: return ["Поиск", "Едет к вам", "На месте", "В пути"]
        case .order: return ["Принят", "Собирают", "Курьер в пути", "У двери"]
        }
    }

    static func kind(for category: DeliveryService.Category) -> LiveActivity.Kind? {
        switch category {
        case .taxi: return .taxi
        case .lavka, .food, .groceries: return .order
        case .parcel: return nil
        }
    }

    // Checked from the last stage back, so «курьер у двери» is «У двери»,
    // not «Курьер в пути». nil stage = the text says nothing about it.
    static func read(_ text: String, kind: LiveActivity.Kind) -> (stage: Int?, finished: Bool, minutes: Int?) {
        let t = text.lowercased()
        let finishedWords: [String]
        let stageWords: [[String]]
        switch kind {
        case .taxi:
            finishedWords = ["поездка завершена", "приехали", "оцените поездку", "спасибо за поездку",
                             "заказ завершён", "заказ завершен", "поездка окончена"]
            stageWords = [
                ["ищем", "поиск", "подбираем"],
                ["назначен", "едет к вам", "приедет", "будет через", "выехал", "водитель найден", "машина найдена"],
                ["подъехал", "ожидает", "на месте", "ждёт вас", "ждет вас", "выходите"],
                ["поездка началась", "в пути", "едем", "хорошей поездки"]
            ]
        case .order:
            finishedWords = ["доставлен", "получен", "оцените заказ", "приятного аппетита", "заказ выполнен",
                             "оцените доставку", "вручен"]
            stageWords = [
                ["принят", "оформлен", "оплачен", "подтвержд"],
                ["готовим", "готовят", "собира", "собран", "упаков"],
                ["курьер", "в пути", "выехал", "передан", "едет"],
                ["у двери", "подъезжает", "прибыл", "на месте", "ждёт", "ждет", "встречайте", "уже рядом"]
            ]
        }
        let done = finishedWords.contains { t.contains($0) }
        var stage: Int?
        for (index, words) in stageWords.enumerated().reversed() where words.contains(where: { t.contains($0) }) {
            stage = index
            break
        }
        return (stage, done, minutes(in: t))
    }

    // «через 4 мин», «7 минут», «через 1 ч 10 мин»
    static func minutes(in t: String) -> Int? {
        var total = 0
        var found = false
        if let h = number(before: ["ч ", "ч.", "час"], in: t) { total += h * 60; found = true }
        if let m = number(before: ["мин"], in: t) { total += m; found = true }
        return found && total < 600 ? total : nil
    }

    private static func number(before units: [String], in t: String) -> Int? {
        let pattern = "(\\d{1,3})\\s*(" + units.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let range = Range(match.range(at: 1), in: t) else { return nil }
        return Int(t[range])
    }
}

// MARK: - Views

// The icon: the app's own picture, or the coloured symbol.
struct LiveActivityIcon: View {
    let activity: LiveActivity
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let icon = activity.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                Image(systemName: activity.symbol)
                    .font(.system(size: size * 0.78, weight: .semibold))
                    .foregroundStyle(activity.tint)
                    .frame(width: size, height: size)
            }
        }
    }
}

// Closed island (main): icon and «4 мин» in the right wing.
struct LiveActivityCompact: View {
    let activity: LiveActivity

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 5) {
                LiveActivityIcon(activity: activity, size: 16)
                Text(activity.shortText(now: context.date))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(activity.finished ? Color(red: 0.4, green: 0.9, blue: 0.5) : activity.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
            }
            .animation(IslandMotion.surface, value: activity.shortText(now: context.date))
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(activity.name): \(activity.status)")
    }
}

// Closed satellite (next to the music): the icon inside a progress ring.
struct LiveActivityBadge: View {
    let activity: LiveActivity
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: activity.progress)
                .stroke(activity.finished ? Color(red: 0.4, green: 0.9, blue: 0.5) : activity.tint,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(IslandMotion.surface, value: activity.progress)
            LiveActivityIcon(activity: activity, size: diameter * 0.46)
        }
        .padding(diameter * 0.14)
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(activity.name): \(activity.status)")
    }
}

// Open: service, stage text, minutes, stage bar with the stage names.
struct LiveActivityExpanded: View {
    let activity: LiveActivity
    var onClose: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .center, spacing: 10) {
                    LiveActivityIcon(activity: activity, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                        Text(activity.status)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    if let m = activity.minutesLeft(now: context.date) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(m == 0 ? "сейчас" : "\(m)")
                                .font(.system(size: m == 0 ? 15 : 24, weight: .bold, design: .rounded))
                                .contentTransition(.numericText())
                            if m > 0 {
                                Text("мин").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .foregroundStyle(activity.tint)
                    } else if activity.finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                    }
                }
                StageBar(activity: activity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StageBar: View {
    let activity: LiveActivity

    var body: some View {
        let stages = activity.stages
        VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(activity.finished ? Color(red: 0.4, green: 0.9, blue: 0.5) : activity.tint)
                        .frame(width: max(6, g.size.width * activity.progress))
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: activity.progress)
                }
            }
            .frame(height: 5)
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, title in
                    Text(title)
                        .font(.system(size: 9, weight: index == activity.stage ? .bold : .medium))
                        .foregroundStyle(.white.opacity(index <= activity.stage || activity.finished ? 0.85 : 0.35))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: index == 0 ? .leading
                               : (index == stages.count - 1 ? .trailing : .center))
                }
            }
        }
    }
}
