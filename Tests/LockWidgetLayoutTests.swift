import Foundation

@main
struct LockWidgetLayoutTests {
    typealias M = LockWidgetLayoutMath
    static func main() {
        let known: Set<String> = ["weather", "battery", "timer", "focus", "airpods"]
        var row: [LockWidgetSlot] = []
        row = M.adding("weather", wide: true, to: row)
        row = M.adding("battery", wide: true, to: row)
        precondition(M.units(row) == 4 && M.free(row) == 0)
        // Full: nothing more fits.
        precondition(M.adding("timer", wide: false, to: row) == row)
        // Shrink one → a small one fits, a wide one becomes small.
        row = M.resizing("battery", in: row)
        precondition(row[1].wide == false && M.free(row) == 1)
        row = M.adding("timer", wide: true, at: 0, to: row)
        precondition(row.first?.kind == "timer" && row.first?.wide == false && M.free(row) == 0)
        // Can't grow when full.
        precondition(M.resizing("timer", in: row) == row)
        // No duplicates.
        precondition(M.adding("weather", wide: false, to: row) == row)
        // Move and remove.
        row = M.moving("timer", to: 2, in: row)
        precondition(row.map(\.kind) == ["weather", "battery", "timer"])
        row = M.removing("weather", from: row)
        precondition(M.free(row) == 2)
        // Insertion index across a centred row: [battery(s), timer(s)].
        precondition(M.insertionIndex(x: 0.1, in: row) == 0)
        precondition(M.insertionIndex(x: 0.5, in: row) == 1)
        precondition(M.insertionIndex(x: 0.95, in: row) == 2)
        // Save / load, unknown kinds dropped, capacity enforced.
        let saved = M.encode(row)
        precondition(M.decode(saved, known: known) == row)
        let messy = ["weather:w", "nope:s", "battery:w", "timer:w"]
        let loaded = M.decode(messy, known: known)
        precondition(loaded.map(\.kind) == ["weather", "battery"] && M.units(loaded) == 4)
        // Old lists keep every widget: four → all small, three → one wide.
        let old = M.migrate(["battery", "timer", "focus", "airpods"], known: known)
        precondition(old.map(\.kind) == ["battery", "timer", "focus", "airpods"] && old.allSatisfy { !$0.wide })
        let three = M.migrate(["battery", "timer", "focus"], known: known)
        precondition(three.map(\.wide) == [true, false, false] && M.units(three) == 4)
        let two = M.migrate(["weather", "battery"], known: known)
        precondition(two.allSatisfy(\.wide))
        print("LockWidgetLayoutTests: OK")
    }
}
