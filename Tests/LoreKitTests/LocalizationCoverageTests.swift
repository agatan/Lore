import Foundation
import Testing

/// 表示言語を切り替えても日本語が残らないことを、文字列表とsourceの両方から確かめる。
@Suite("翻訳の網羅")
struct LocalizationCoverageTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let languages = ["en", "ja", "zh-Hans"]

    /// 翻訳しないと決めたもの。DEBUG専用の収録・snapshot用file。
    static let excludedFiles: Set<String> = [
        "DebugRecorder.swift",
        "DebugSnapshotter.swift",
        "ScreenshotDemoData.swift",
    ]

    /// 翻訳しないと決めた文字列。ログにだけ出す理由と、LLMへ送る疎通確認のprompt。
    static let untranslatedLiterals: Set<String> = [
        "保存処理が完了しました",
        "終了期限に到達しました。保存済みデータは次回起動時に回収します",
        "押下",
        "離上 %@ms (閾値 %@ms)",
        "語彙変更",
        "音声認識設定変更",
        "入力をそのまま返してください。",
        "疎通確認",
    ]

    static func table(_ language: String) throws -> [String: String] {
        let url = repository.appending(path: "Sources/LoreKit/Resources/\(language).lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }

    @Test("三言語の文字列表は同じkeyを持ち、空の値がない")
    func tablesHaveSameKeys() throws {
        let english = try Self.table("en")
        for language in Self.languages {
            let table = try Self.table(language)
            let missing = Set(english.keys).subtracting(table.keys).sorted()
            let extra = Set(table.keys).subtracting(english.keys).sorted()
            #expect(missing.isEmpty, "\(language)に無いkey: \(missing)")
            #expect(extra.isEmpty, "\(language)だけにあるkey: \(extra)")
            let empty = table.filter { $0.value.isEmpty }.keys.sorted()
            #expect(empty.isEmpty, "\(language)の空の値: \(empty)")
        }
    }

    @Test("jaはkeyをそのまま値に使う")
    func japaneseMapsKeyToItself() throws {
        let mismatched = try Self.table("ja").filter { $0.key != $0.value }.keys.sorted()
        #expect(mismatched.isEmpty, "\(mismatched)")
    }

    @Test("翻訳はkeyと同じformat specifierを持つ")
    func formatSpecifiersMatch() throws {
        for language in Self.languages {
            for (key, value) in try Self.table(language) {
                #expect(
                    FormatSpecifiers.types(in: value) == FormatSpecifiers.types(in: key),
                    "\(language): \(key) = \(value)"
                )
            }
        }
    }

    @Test("UIとAppの日本語literalはすべて文字列表のkeyにある")
    func sourceLiteralsAreLocalized() throws {
        let keys = Set(try Self.table("en").keys.map(FormatSpecifiers.normalized))
        var missing: [String] = []
        for directory in ["Sources/LoreKit/UI", "Sources/LoreKit/App"] {
            let root = Self.repository.appending(path: directory)
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                guard !Self.excludedFiles.contains(url.lastPathComponent) else { continue }
                var scanner = SwiftLiteralScanner(try String(contentsOf: url, encoding: .utf8))
                for literal in scanner.scan() where literal.containsJapanese {
                    let key = FormatSpecifiers.normalized(literal)
                    guard !keys.contains(key), !Self.untranslatedLiterals.contains(key) else { continue }
                    missing.append("\(url.lastPathComponent): \(literal)")
                }
            }
        }
        #expect(missing.isEmpty, "文字列表に無い日本語literal:\n\(missing.joined(separator: "\n"))")
    }

    @Test("scannerはコメント、DEBUG、ログを除き、補間をformat specifierにする")
    func scannerSkipsNonDisplayCode() {
        var scanner = SwiftLiteralScanner(#"""
        // "コメント"
        Text("表示 \(count) 件")
        LoreLog.ui.info("ログ \(name, privacy: .public)")
        #if DEBUG
        Text("デバッグ")
        #else
        Text("リリース")
        #endif
        """#)
        #expect(scanner.scan() == ["表示 %@ 件", "リリース"])
    }
}

private enum FormatSpecifiers {
    private static var pattern: Regex<(Substring, Substring?, Substring)> {
        /%(?:(\d+)\$)?(?:\.\d+)?(@|lld|ld|llu|lu|d|u|f)/
    }

    /// 引数位置ごとの型。`%@ %@`と`%1$@ %2$@`は同じとみなす。
    static func types(in text: String) -> [String] {
        var types: [Int: String] = [:]
        var next = 1
        for match in text.replacing("%%", with: "").matches(of: pattern) {
            let position = match.output.1.flatMap { Int($0) } ?? next
            types[position] = String(match.output.2)
            next = position + 1
        }
        return types.keys.sorted().map { types[$0]! }
    }

    /// 型を区別せず、source側の補間(`%@`)とkeyを突き合わせる。
    static func normalized(_ text: String) -> String {
        text.replacing(pattern, with: "%@")
    }
}

/// Swift sourceから文字列literalを取り出す。表示されないもの(コメント、`#if DEBUG`の中、`LoreLog`呼び出し)は除く。
private struct SwiftLiteralScanner {
    private let characters: [Character]
    private var index = 0
    private var literals: [String] = []

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func scan() -> [String] {
        while index < characters.count {
            if starts(with: "//") {
                skip(past: "\n")
            } else if starts(with: "/*") {
                skip(past: "*/")
            } else if starts(with: "#if DEBUG") {
                skipDebugBlock()
            } else if starts(with: "LoreLog.") {
                let count = literals.count
                skip(past: "(")
                skipBalancedParentheses()
                literals.removeSubrange(count...)
            } else if characters[index] == "\"" {
                literals.append(readString())
            } else {
                index += 1
            }
        }
        return literals
    }

    private func starts(with text: String) -> Bool {
        characters[index...].starts(with: text)
    }

    private mutating func skip(past text: String) {
        while index < characters.count, !starts(with: text) { index += 1 }
        index = min(characters.count, index + text.count)
    }

    /// `#else`以降はrelease buildにも入るので読む。
    private mutating func skipDebugBlock() {
        var depth = 0
        while index < characters.count {
            if starts(with: "#if") {
                depth += 1
            } else if starts(with: "#endif") {
                depth -= 1
                if depth == 0 { index += "#endif".count; return }
            } else if depth == 1, starts(with: "#else") {
                index += "#else".count
                return
            }
            index += 1
        }
    }

    /// 開き括弧の直後から、対応する閉じ括弧の直後まで進める。中の文字列literalも集める。
    private mutating func skipBalancedParentheses() {
        var depth = 1
        while index < characters.count, depth > 0 {
            switch characters[index] {
            case "\"": literals.append(readString()); continue
            case "(": depth += 1
            case ")": depth -= 1
            default: break
            }
            index += 1
        }
    }

    private mutating func readString() -> String {
        let delimiter = starts(with: "\"\"\"") ? "\"\"\"" : "\""
        index += delimiter.count
        var text = ""
        while index < characters.count, !starts(with: delimiter) {
            guard characters[index] == "\\", index + 1 < characters.count else {
                text.append(characters[index])
                index += 1
                continue
            }
            let escaped = characters[index + 1]
            index += 2
            switch escaped {
            case "(":
                skipBalancedParentheses()
                text += "%@"
            case "n": text += "\n"
            case "t": text += "\t"
            default: text.append(escaped)
            }
        }
        index += delimiter.count
        return text
    }
}

private extension String {
    var containsJapanese: Bool {
        unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
        }
    }
}
