import Foundation
import Testing

@testable import KoeKit

/// `EngineError` の判別。
///
/// `needsAppRestart` は「このプロセスでは直せない」ことを状態機械の外まで運ぶための型で、
/// 受け取る側（`DictationCoordinator.fail`）は `any Error` 越しに判別する。ここが黙って
/// 通らなくなると、起動し直しが起きないまま「再起動してください」の表示だけが残る。
@Suite("エンジンの失敗の判別")
struct EngineErrorTests {
    @Test("needsAppRestart は any Error 越しでも判別できる")
    func matchesThroughExistential() {
        let error: any Error = EngineError.needsAppRestart("使えなくなりました")

        var matched = false
        if case EngineError.needsAppRestart = error { matched = true }

        #expect(matched)
    }

    @Test("ほかの失敗を needsAppRestart と取り違えない")
    func doesNotMatchOtherFailures() {
        let others: [any Error] = [
            EngineError.notReady("未取得です"),
            EngineError.timedOut,
            EngineError.cancelled,
            EngineError.failed("失敗"),
        ]

        for error in others {
            var matched = false
            if case EngineError.needsAppRestart = error { matched = true }
            #expect(!matched, "\(error) を needsAppRestart と判定した")
        }
    }

    @Test("文言はそのまま表に出る")
    func surfacesMessage() {
        #expect(EngineError.needsAppRestart("再起動してください").localizedDescription == "再起動してください")
    }
}
