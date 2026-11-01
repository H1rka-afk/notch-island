import Foundation

// swiftc -parse-as-library Source/EyeBreakPolicy.swift Tests/EyeBreakTests.swift -o eb && ./eb
@main
struct EyeBreakTests {
    static func main() {
        var p = EyeBreakPolicy()
        // 39 checks of 30 s with input = 19.5 min: not yet.
        for _ in 0..<39 { precondition(!p.tick(elapsed: 30, idle: 5)) }
        // The 40th (20 min) — due.
        precondition(p.tick(elapsed: 30, idle: 5))
        p.reset()
        precondition(p.worked == 0)

        // Reading without touching the mouse (idle 2 min) does not count…
        _ = p.tick(elapsed: 30, idle: 5)
        _ = p.tick(elapsed: 30, idle: 120)
        precondition(p.worked == 30)
        // …and being away 5 min resets the count.
        _ = p.tick(elapsed: 30, idle: 300)
        precondition(p.worked == 0)

        // Banner: «Вдаль» first, then the countdown with a falling bar.
        precondition(EyeBreakPolicy.banner(at: 0).text == "Вдаль")
        precondition(EyeBreakPolicy.banner(at: 2) == ("18 с", 0.9))
        precondition(EyeBreakPolicy.banner(at: 19).text == "1 с")
        precondition(EyeBreakPolicy.banner(at: 25).text == "0 с")
        print("EyeBreakTests: OK")
    }
}
