import Foundation

// swiftc -parse-as-library Source/WidgetFormat.swift Tests/WidgetFormatTests.swift -o wf && ./wf
@main
struct WidgetFormatTests {
    static func main() {
        let list = AccessoryBattery.cleaned([
            AccessoryBattery(name: "Magic Keyboard", percent: 80),
            AccessoryBattery(name: "Magic Mouse", percent: 12),
            AccessoryBattery(name: "magic mouse", percent: 12),     // same device twice
            AccessoryBattery(name: "AirPods Pro", percent: 50),     // own widget
            AccessoryBattery(name: "Broken", percent: 255)
        ])
        precondition(list.map(\.name) == ["Magic Mouse", "Magic Keyboard"], "\(list)")
        precondition(AccessoryBattery.heading(list) == "Magic Mouse и ещё 1")
        precondition(AccessoryBattery.heading([]) == "")
        precondition(AccessoryBattery.symbol(for: "Magic Mouse") == "computermouse.fill")
        precondition(AccessoryBattery.symbol(for: "Magic Keyboard with Touch ID") == "keyboard.fill")
        precondition(AccessoryBattery.symbol(for: "Magic Trackpad") == "hand.point.up.left.fill")

        precondition(SystemLoad.fraction(busy: 1, total: 4) == 0.25)
        precondition(SystemLoad.fraction(busy: 1, total: 0) == nil)
        precondition(SystemLoad.fraction(busy: 9, total: 4) == 1)
        precondition(SystemLoad.percent(0.234) == "23 %" && SystemLoad.percent(nil) == "—")

        precondition(SunFormat.dayLength(9 * 3600 + 12 * 60) == "Световой день 9 ч 12 мин")
        let utc = TimeZone(identifier: "UTC")!
        precondition(SunFormat.time(Date(timeIntervalSince1970: 7 * 3600 + 41 * 60), in: utc) == "07:41")
        print("WidgetFormatTests: OK")
    }
}
