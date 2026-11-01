import Foundation

// swiftc -parse-as-library Source/IslandProfiles.swift Tests/IslandProfilesTests.swift -o pr-tests && ./pr-tests
@main
struct IslandProfilesTests {
    static func main() {
        let iphone = IslandProfiles.preset(.iphone)!
        let extended = IslandProfiles.preset(.extended)!

        // Every managed key is defined by both presets.
        precondition(Set(iphone.keys) == Set(IslandProfiles.allKeys))
        precondition(Set(extended.keys) == Set(IslandProfiles.allKeys))

        // iPhone: no shelf, clipboard, volume…; lock, focus, privacy on.
        precondition(iphone["shelf"] == false && iphone["clipboard"] == false && iphone["volume"] == false)
        precondition(iphone["lockIsland"] == true && iphone["focus"] == true && iphone["privacy"] == true)
        precondition(iphone["hideSource"] == true)

        // Matching.
        precondition(IslandProfiles.match(iphone) == .iphone)
        precondition(IslandProfiles.match(extended) == .extended)
        var noCalendar = extended
        noCalendar["calendar"] = false; noCalendar["reminders"] = false
        precondition(IslandProfiles.match(noCalendar) == .extended)
        var tweaked = iphone
        tweaked["shelf"] = true
        precondition(IslandProfiles.match(tweaked) == .custom)
        precondition(IslandProfiles.match([:]) == .custom)

        // Applying: calendar stays off without permission, on with it.
        let off = IslandProfiles.values(for: .extended, saved: nil, current: iphone) { _ in false }
        precondition(off["calendar"] == false && off["shelf"] == true)
        let on = IslandProfiles.values(for: .extended, saved: nil, current: iphone) { _ in true }
        precondition(on["calendar"] == true)

        // Custom restores the remembered set; without one keeps the current.
        precondition(IslandProfiles.values(for: .custom, saved: tweaked, current: iphone) { _ in true } == tweaked)
        precondition(IslandProfiles.values(for: .custom, saved: nil, current: extended) { _ in true } == extended)

        // 3.11.0: new switches are part of both presets.
        for key in ["airdrop", "lockMedia", "lockWidgets", "coverAnimated"] {
            precondition(iphone[key] == true && extended[key] == true, key)
        }

        // 4.3.3: StandBy, wings, cinema and the player style are managed too.
        let quiet = IslandProfiles.preset(.quiet)!
        precondition(Set(quiet.keys) == Set(IslandProfiles.allKeys))
        for key in ["standby", "cinema", "playerNew"] { precondition(iphone[key] == true, key) }
        precondition(iphone["wings"] == false && extended["wings"] == true)
        precondition(quiet["airdrop"] == false && quiet["cinema"] == true && quiet["lockIsland"] == true)
        precondition(IslandProfiles.match(quiet) == .quiet)
        precondition(IslandProfiles.match(iphone) == .iphone)

        // User profiles: clean names, unique names, matching, export/import.
        precondition(UserProfileStore.cleanName("   ") == "Мой профиль")
        precondition(UserProfileStore.cleanName(String(repeating: "я", count: 99)).count == UserProfileStore.maxName)
        var work = UserProfileStore.make(name: " Работа ", summary: " Тихо, без баннеров ",
                                         values: ["shelf": true, "volume": false, "bogus": true])
        precondition(work.name == "Работа" && work.summary == "Тихо, без баннеров")
        precondition(work.values == ["shelf": true, "volume": false])
        precondition(UserProfileStore.uniqueName("работа", among: [work]) == "работа 2")
        precondition(UserProfileStore.uniqueName("Дом", among: [work]) == "Дом")
        precondition(UserProfileStore.match(["shelf": true, "volume": false, "vpn": true], in: [work]) == work.id)
        precondition(UserProfileStore.match(["shelf": false], in: [work]) == nil)

        let data = UserProfileStore.exportData(work)!
        let back = UserProfileStore.importProfile(from: data)!
        precondition(back.name == work.name && back.summary == work.summary && back.values == work.values)
        precondition(back.id != work.id)
        precondition(UserProfileStore.importProfile(from: Data("{}".utf8)) == nil)
        precondition(UserProfileStore.importProfile(from: Data("{\"format\":\"other\",\"version\":1,\"name\":\"x\",\"description\":\"\",\"values\":{\"shelf\":true}}".utf8)) == nil)
        work.name = "a/b:c"
        precondition(UserProfileStore.fileName(for: work) == "a-b-c.notchprofile")

        let suite = UserDefaults(suiteName: "nip-profiles-test-\(UUID().uuidString)")!
        UserProfileStore.save([work], suite)
        precondition(UserProfileStore.load(suite) == [work])

        print("IslandProfilesTests: OK")
    }
}
