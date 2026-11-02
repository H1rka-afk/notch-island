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
        // 4.7.0: sections titled «Ovira …» are read too.
        precondition(ReleaseNotes.parse("Ovira 4.8.0 — новое\n- раз\n- два\nOvira 4.7.0\n- старое") == ["раз", "два"])
        print("ReleaseNotesTests: OK")
    }
}
