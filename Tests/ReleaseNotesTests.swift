import Foundation

// swiftc -parse-as-library Source/ReleaseNotes.swift Tests/ReleaseNotesTests.swift -o rn && ./rn
@main
struct ReleaseNotesTests {
    static func main() {
        let readme = """
        Notch Island 3.20.0 — знакомство в настройках

        - Первое: тур внутри окна.
        - Второе: описание обновления
          продолжается на следующей строке.
        Обычное предложение.

        Notch Island 3.19.0 — тема «Обложка»

        - Старое, не показывать.
        """
        let items = ReleaseNotes.parse(readme)
        precondition(items == ["Первое: тур внутри окна.",
                               "Второе: описание обновления продолжается на следующей строке.",
                               "Обычное предложение."], "\(items)")
        precondition(ReleaseNotes.parse("").isEmpty)
        precondition(ReleaseNotes.parse("просто текст без заголовка").isEmpty)
        let many = "Notch Island 9.9.9\n" + (1...20).map { "- п\($0)" }.joined(separator: "\n")
        precondition(ReleaseNotes.parse(many).count == 10)
        print("ReleaseNotesTests: OK")
    }
}
