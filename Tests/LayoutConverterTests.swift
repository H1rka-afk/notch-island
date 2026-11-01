import Foundation

// swiftc -parse-as-library Source/LayoutConverter.swift Tests/LayoutConverterTests.swift -o lc && ./lc
@main
struct LayoutConverterTests {
    static func main() {
        let a = LayoutConverter.convert("ghbdtn")
        precondition(a.text == "привет" && a.toRussian, "\(a)")
        let b = LayoutConverter.convert("руддщ")
        precondition(b.text == "hello" && !b.toRussian, "\(b)")
        precondition(LayoutConverter.convert("Ghbdtn? vbh!").text == "Привет, мир!")
        precondition(LayoutConverter.convert("Руддщ").text == "Hello")
        precondition(LayoutConverter.convert("zyltrc").text == "яндекс")
        precondition(LayoutConverter.convert("'njn ntrcn").text == "этот текст")
        precondition(LayoutConverter.convert("ытщц").text == "snow")
        // Round trip.
        let words = "съешь же ещё этих мягких французских булок, да выпей чаю."
        let typed = LayoutConverter.convert(words).text
        precondition(LayoutConverter.convert(typed).text == words, typed)
        // Nothing to convert.
        precondition(LayoutConverter.convert("123 456").text == "123 456")
        print("LayoutConverterTests: OK")
    }
}
