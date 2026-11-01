import Foundation

// swiftc -parse-as-library Source/FocusModeParser.swift Tests/FocusModeTests.swift -o focus-tests && ./focus-tests
// Fixtures follow the real structure of ~/Library/DoNotDisturb/DB on macOS
// (captured from a MacBook Air with a 0:00–8:00 "Do Not Disturb" schedule).
@main
struct FocusModeTests {
    static func json(_ text: String) -> Data {
        let data = Data(text.utf8)
        precondition(FocusDatabaseParser.isWellFormed(data), "test JSON is malformed")
        return data
    }

    static func main() {
        let configurations = json(#"""
        {"data":[{"modeConfigurations":{
          "com.apple.donotdisturb.mode.default":{
            "mode":{"name":"Do Not Disturb","symbolImageName":"moon.fill","tintColorName":"systemIndigoColor"},
            "triggers":{"triggers":[{"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":2,
              "timePeriodStartTimeHour":0,"timePeriodStartTimeMinute":0,
              "timePeriodEndTimeHour":8,"timePeriodEndTimeMinute":0,"timePeriodWeekdays":31}]}},
          "com.apple.donotdisturb.mode.bookmarkfill":{
            "mode":{"name":"H1rka","symbolImageName":"bookmark.fill","tintColorName":"systemGrayColor"}}
        }}]}
        """#)

        // 1. Manual "Do Not Disturb" on (real 03:56 snapshot): the invalidate-all
        //    request has the SAME timestamp as the new assertion → active.
        let manualOn = json(#"""
        {"data":[{
          "storeInvalidationRequestRecords":[{"invalidationRequestPredicate":{"invalidationPredicateType":"any"},
            "invalidationRequestReason":"user-changed-state","invalidationRequestDateTimestamp":814928171.759819}],
          "storeInvalidationRecords":[{"invalidationAssertion":{"assertionStartDateTimestamp":814928050.129842,
            "assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default",
              "assertionDetailsLifetime":{"assertionDetailsLifetimeType":"schedule"}}},
            "invalidationDateTimestamp":814928108.788849}],
          "storeAssertionRecords":[{"assertionStartDateTimestamp":814928171.759819,
            "assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default",
              "assertionDetailsReason":"user-action"}}]
        }],"header":{"version":8}}
        """#)
        let on = FocusDatabaseParser.activeMode(assertionsJSON: manualOn, configurationsJSON: configurations)
        precondition(on == FocusMode(identifier: "com.apple.donotdisturb.mode.default", name: "Не беспокоить",
                                     symbol: "moon.fill", tintName: "systemIndigoColor", scheduled: false))

        // 2. Turned off INSIDE the 0:00–8:00 schedule (real 04:07 snapshot):
        //    no assertion records at all → off. 3.1.9 wrongly reported "on".
        let manualOff = json(#"""
        {"data":[{
          "storeInvalidationRequestRecords":[{"invalidationRequestPredicate":{"invalidationPredicateType":"any"},
            "invalidationRequestDateTimestamp":814928861.0}],
          "storeInvalidationRecords":[{"invalidationAssertion":{"assertionStartDateTimestamp":814928860.0,
            "assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}},
            "invalidationDateTimestamp":814928861.0}]
        }],"header":{"version":8}}
        """#)
        precondition(FocusDatabaseParser.activeMode(assertionsJSON: manualOff, configurationsJSON: configurations) == nil)

        // 3. Scheduled activation is recorded by macOS itself.
        let scheduledOn = json(#"""
        {"data":[{"storeAssertionRecords":[{"assertionStartDateTimestamp":814928050.0,
          "assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default",
            "assertionDetailsLifetime":{"assertionDetailsLifetimeType":"schedule"}}}]}]}
        """#)
        precondition(FocusDatabaseParser.activeMode(assertionsJSON: scheduledOn, configurationsJSON: configurations)?.scheduled == true)

        // 4. A stale assertion older than an invalidate-all request is ignored.
        let stale = json(#"""
        {"data":[{
          "storeInvalidationRequestRecords":[{"invalidationRequestPredicate":{"invalidationPredicateType":"any"},
            "invalidationRequestDateTimestamp":500.0}],
          "storeAssertionRecords":[{"assertionStartDateTimestamp":400.0,
            "assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}
        """#)
        precondition(FocusDatabaseParser.activeMode(assertionsJSON: stale, configurationsJSON: configurations) == nil)

        // 5. Newest assertion wins; custom mode uses its own name/symbol/tint.
        let custom = json(#"""
        {"data":[{"storeAssertionRecords":[
          {"assertionStartDateTimestamp":100.0,"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}},
          {"assertionStartDateTimestamp":200.0,"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.bookmarkfill"}}]}]}
        """#)
        precondition(FocusDatabaseParser.activeMode(assertionsJSON: custom, configurationsJSON: configurations)
                     == FocusMode(identifier: "com.apple.donotdisturb.mode.bookmarkfill", name: "H1rka",
                                  symbol: "bookmark.fill", tintName: "systemGrayColor", scheduled: false))

        // 6. Missing data and unknown modes.
        precondition(FocusDatabaseParser.activeMode(assertionsJSON: nil, configurationsJSON: nil) == nil)
        let unknown = FocusDatabaseParser.describe("X", configuration: ["mode": ["name": "  "] as [String: Any]],
                                                   scheduled: false)
        precondition(unknown.name == "Фокусирование" && unknown.symbol == "moon.fill")

        // 7. Half-written file is detected.
        precondition(!FocusDatabaseParser.isWellFormed(Data("{\"data\":[".utf8)))

        print("FocusModeTests: OK")
    }
}
