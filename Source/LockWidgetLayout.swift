import Foundation

// 4.6.0 — the row of widgets under the lock-screen clock, like on iPhone:
// four places; a small widget takes one, a wide one takes two. Pure logic
// (tested): adding, removing, reordering, resizing, saving.
struct LockWidgetSlot: Equatable, Codable {
    var kind: String
    var wide: Bool

    var units: Int { wide ? 2 : 1 }
}

enum LockWidgetLayoutMath {
    static let capacity = 4

    static func units(_ slots: [LockWidgetSlot]) -> Int { slots.reduce(0) { $0 + $1.units } }

    static func free(_ slots: [LockWidgetSlot]) -> Int { capacity - units(slots) }

    // Adds `kind` at `index` (end when nil). Wide if asked and it fits,
    // otherwise small; nothing when even a small one doesn't fit or the
    // widget is already there.
    static func adding(_ kind: String, wide: Bool, at index: Int? = nil,
                       to slots: [LockWidgetSlot]) -> [LockWidgetSlot] {
        guard !slots.contains(where: { $0.kind == kind }) else { return slots }
        let room = free(slots)
        guard room >= 1 else { return slots }
        let slot = LockWidgetSlot(kind: kind, wide: wide && room >= 2)
        var result = slots
        let position = min(max(0, index ?? result.count), result.count)
        result.insert(slot, at: position)
        return result
    }

    static func removing(_ kind: String, from slots: [LockWidgetSlot]) -> [LockWidgetSlot] {
        slots.filter { $0.kind != kind }
    }

    static func moving(_ kind: String, to index: Int, in slots: [LockWidgetSlot]) -> [LockWidgetSlot] {
        guard let from = slots.firstIndex(where: { $0.kind == kind }) else { return slots }
        var result = slots
        let slot = result.remove(at: from)
        result.insert(slot, at: min(max(0, index), result.count))
        return result
    }

    // Small ↔ wide; becoming wide only when the extra place is free.
    static func resizing(_ kind: String, in slots: [LockWidgetSlot]) -> [LockWidgetSlot] {
        guard let i = slots.firstIndex(where: { $0.kind == kind }) else { return slots }
        var result = slots
        if result[i].wide { result[i].wide = false }
        else if free(slots) >= 1 { result[i].wide = true }
        return result
    }

    // Where a widget dropped at `x` (0…1 across the row) lands, given the
    // other widgets (in units, centred row).
    static func insertionIndex(x: Double, in slots: [LockWidgetSlot]) -> Int {
        let total = max(1, units(slots))
        var acc = 0.0
        for (i, slot) in slots.enumerated() {
            let mid = (acc + Double(slot.units) / 2) / Double(total)
            if x < mid { return i }
            acc += Double(slot.units)
        }
        return slots.count
    }

    // «kind:w» / «kind:s», comma separated.
    static func encode(_ slots: [LockWidgetSlot]) -> [String] {
        slots.map { "\($0.kind):\($0.wide ? "w" : "s")" }
    }

    static func decode(_ raw: [String], known: Set<String>) -> [LockWidgetSlot] {
        var result: [LockWidgetSlot] = []
        for item in raw {
            let parts = item.split(separator: ":")
            guard let kind = parts.first.map(String.init), known.contains(kind) else { continue }
            let wide = parts.count < 2 || parts[1] == "w"
            result = adding(kind, wide: wide, to: result)
        }
        return result
    }

    // Before 4.6.0 up to four wide tiles were shown. Keep every widget and
    // the order: as many stay wide as the four places allow.
    static func migrate(_ old: [String], known: Set<String>) -> [LockWidgetSlot] {
        var kinds: [String] = []
        for kind in old where known.contains(kind) && !kinds.contains(kind) { kinds.append(kind) }
        kinds = Array(kinds.prefix(capacity))
        let wideCount = max(0, capacity - kinds.count)
        return kinds.enumerated().map { LockWidgetSlot(kind: $1, wide: $0 < wideCount) }
    }
}
