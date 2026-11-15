import Foundation
import Testing
@testable import LoreKit

struct PlainTextCase: CustomTestStringConvertible, Sendable {
    var name: String
    var input: String
    var expected: String

    var testDescription: String { name }
}

@Suite("Event description text")
struct EventDescriptionTextTests {
    static let cases: [PlainTextCase] = [
        .init(name: "Plain text is returned as it is, with its line breaks", input: "Agenda\n- one\n- two\n\nSee you.", expected: "Agenda\n- one\n- two\n\nSee you."),
        .init(name: "Plain text keeps ampersands that are not references", input: "Q&A and R&D; a < b", expected: "Q&A and R&D; a < b"),
        .init(name: "An address in angle brackets is not a tag", input: "Join <https://meet.google.com/abc-defg-hij>\nBring notes", expected: "Join <https://meet.google.com/abc-defg-hij>\nBring notes"),
        .init(name: "Paragraphs are separated by a blank line", input: "<p>First</p><p>Second</p>", expected: "First\n\nSecond"),
        .init(name: "br ends a line, in any spelling", input: "One<br>Two<br/>Three<BR />Four", expected: "One\nTwo\nThree\nFour"),
        .init(name: "Source line breaks and indentation are not line breaks", input: "<div>\n    Hello\n    world\n</div>", expected: "Hello world"),
        .init(name: "A list becomes bullets", input: "<ul><li>Roadmap</li><li>Hiring</li></ul>", expected: "• Roadmap\n• Hiring"),
        .init(name: "An ordered list also uses bullets", input: "<p>Topics</p><ol><li>A</li><li>B</li></ol>", expected: "Topics\n\n• A\n• B"),
        .init(name: "Inline markup keeps its text", input: "<b>Bold</b> and <i>italic</i> and <span style=\"color:red\">red</span>", expected: "Bold and italic and red"),
        .init(name: "Headings end a line", input: "<h2>Notes</h2>Bring a laptop", expected: "Notes\nBring a laptop"),
        .init(name: "Named references", input: "<p>Tom &amp; Jerry &lt;3 &quot;cheese&quot; &#39;x&#39;&nbsp;y</p>", expected: "Tom & Jerry <3 \"cheese\" 'x' y"),
        .init(name: "Numeric references", input: "<p>&#x1F600; &#12354; &#65;</p>", expected: "😀 あ A"),
        .init(name: "An unknown reference stays as typed", input: "<p>&bogus; &amp</p>", expected: "&bogus; &amp"),
        .init(name: "A link whose text is its address shows the address once", input: "<a href=\"https://meet.google.com/abc-defg-hij\">https://meet.google.com/abc-defg-hij</a>", expected: "https://meet.google.com/abc-defg-hij"),
        .init(name: "A link whose text differs shows text and address", input: "Join <a href=\"https://example.com/room?x=1&amp;y=2\">the room</a> now", expected: "Join the room (https://example.com/room?x=1&y=2) now"),
        .init(name: "A link without a web address shows its text only", input: "<a href=\"javascript:alert(1)\">click</a> <a href=\"mailto:a@example.com\">mail</a>", expected: "click mail"),
        .init(name: "A link without text shows the address", input: "<a href='https://example.com/a'></a>", expected: "https://example.com/a"),
        .init(name: "Script and style content is dropped", input: "<style>p{color:red}</style><p>Hi</p><script>alert('x')</script>", expected: "Hi"),
        .init(name: "Comments are dropped", input: "A<!-- hidden <b> -->B", expected: "AB"),
        .init(name: "Unclosed and stray tags do not lose text", input: "<p>One<p>Two</b></div>Three", expected: "One\nTwo\nThree"),
        .init(name: "A table reads row by row", input: "<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>", expected: "A B\nC D"),
        .init(name: "Many blank lines collapse to one", input: "<p>A</p><br><br><br><p>B</p>", expected: "A\n\nB"),
        .init(name: "Japanese text and a Google style description", input: "<p>今日の確認事項</p><ul><li>初回体験</li></ul><p>Google Meet に参加: <a href=\"https://meet.google.com/abc-defg-hij\">https://meet.google.com/abc-defg-hij</a></p>", expected: "今日の確認事項\n\n• 初回体験\n\nGoogle Meet に参加: https://meet.google.com/abc-defg-hij"),
        .init(name: "Empty", input: "", expected: ""),
        .init(name: "Only markup", input: "<p> </p><br>", expected: ""),
    ]

    @Test("HTML or plain text becomes plain text", arguments: cases)
    func plainText(_ testCase: PlainTextCase) {
        #expect(EventDescriptionText.plainText(from: testCase.input) == testCase.expected)
    }

    @Test("Windows line breaks are normalized")
    func windowsLineBreaks() {
        #expect(EventDescriptionText.plainText(from: "a\r\nb\rc") == "a\nb\nc")
    }

    @Test("A short text is not cut")
    func shortPreview() {
        let preview = EventDescriptionText.preview("one\ntwo", maxLines: 3, maxCharacters: 100)
        #expect(preview == .init(text: "one\ntwo", isCut: false))
    }

    @Test("A text of exactly the limits is not cut")
    func exactPreview() {
        let preview = EventDescriptionText.preview("ab\ncd", maxLines: 2, maxCharacters: 5)
        #expect(!preview.isCut)
    }

    @Test("Extra lines are cut")
    func linePreview() {
        let preview = EventDescriptionText.preview("1\n2\n3\n4", maxLines: 2, maxCharacters: 100)
        #expect(preview == .init(text: "1\n2…", isCut: true))
    }

    @Test("A character cut moves back to the last whitespace")
    func characterPreview() {
        let preview = EventDescriptionText.preview("alpha beta gamma", maxLines: 5, maxCharacters: 12)
        #expect(preview == .init(text: "alpha beta…", isCut: true))
    }

    @Test("A cut that falls between words keeps the whole word")
    func boundaryPreview() {
        let preview = EventDescriptionText.preview("alpha beta gamma", maxLines: 5, maxCharacters: 10)
        #expect(preview == .init(text: "alpha beta…", isCut: true))
    }

    @Test("A long address is not split when a word boundary exists before it")
    func addressPreview() {
        let text = "Join: https://example.com/a/very/long/path"
        let preview = EventDescriptionText.preview(text, maxLines: 5, maxCharacters: 20)
        #expect(preview == .init(text: "Join:…", isCut: true))
    }

    @Test("A single long word is cut at the limit")
    func longWordPreview() {
        let preview = EventDescriptionText.preview(String(repeating: "x", count: 30), maxLines: 5, maxCharacters: 10)
        #expect(preview == .init(text: String(repeating: "x", count: 10) + "…", isCut: true))
    }

    @Test("Text without spaces, such as Japanese, is cut at the limit")
    func japanesePreview() {
        let preview = EventDescriptionText.preview("今日の確認事項と次のリリースの範囲", maxLines: 5, maxCharacters: 6)
        #expect(preview == .init(text: "今日の確認事…", isCut: true))
    }

    @Test("Web addresses are found, other schemes are not")
    func links() {
        let text = "Join https://meet.google.com/abc-defg-hij or http://example.com/a. Files: file:///etc/hosts Mail: a@example.com tel:+15550100"
        let found = EventDescriptionText.links(in: text).map { $0.url.absoluteString }
        #expect(found == ["https://meet.google.com/abc-defg-hij", "http://example.com/a"])
    }

    @Test("Link ranges point at the address in the text")
    func linkRanges() throws {
        let text = "See https://example.com/x now"
        let link = try #require(EventDescriptionText.links(in: text).first)
        #expect(String(text[link.range]) == "https://example.com/x")
    }
}
