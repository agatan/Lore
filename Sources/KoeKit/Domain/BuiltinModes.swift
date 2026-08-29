import Foundation

/// Default と、初回に編集可能な例として入れるモード群。
/// Default だけがアプリの標準で、ほかはユーザー作成モードと同じ扱いにする。
public enum BuiltinModes {
    public static let defaultModeID = "builtin.default"
    public static let retiredModeIDs: Set<String> = ["builtin.ai-agent"]

    public static var all: [Mode] {
        [defaultMode, chat, mailAndDocs, memo, code]
    }

    public static func initialMode(id: String) -> Mode? {
        all.first { $0.id == id }
    }

    public static let defaultMode = Mode(
        id: defaultModeID,
        name: "Default",
        bundleIDs: [],
        prompt: """
        そのまま読める文章になるよう構造化してください。

        - 話が複数の項目に分かれているときは箇条書き(- )にする。ただし 1 つの話を工程に分解して項目を増やしてはいけない
        - 話題が変わったところで段落を分ける(空行を入れる)
        - 元の口調と丁寧さの度合いを保つ。敬語を足して丁寧にしすぎない。「〜させていただきます」のような過剰な言い換えはしない
        - 見出し・番号付きリスト・太字は、発話でそう指示していない限り付けない
        - 一言だけの発話は無理に構造化せず、1 文のまま返す
        """,
        sortOrder: 0,
        isBuiltin: true
    )

    public static let chat = Mode(
        id: "builtin.chat",
        name: "Chat",
        bundleIDs: [
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.microsoft.teams2",
            "com.apple.MobileSMS",
            "ru.keepcoder.Telegram",
        ],
        prompt: """
        チャットに投稿するメッセージとして整形してください。

        - 話し言葉の距離感を保つ。硬い書き言葉に直しすぎない
        - 短く読みやすく。1〜3 文程度にまとめ、改行は意味の切れ目だけに入れる
        - 「です・ます」は残すが、恐縮しすぎた定型句(お忙しいところ恐れ入りますが等)は足さない
        - 絵文字や装飾は発話に含まれていない限り追加しない
        """,
        sortOrder: 20,
        isBuiltin: false
    )

    public static let mailAndDocs = Mode(
        id: "builtin.mail-docs",
        name: "Mail / Docs",
        bundleIDs: [
            "com.apple.mail",
            "com.readdle.smartemail-Mac",
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.notion.id",
            "com.apple.iWork.Pages",
        ],
        prompt: """
        メールやドキュメントの本文として整形してください。

        - 「です・ます」調に統一する
        - 意味のまとまりごとに段落を分ける(空行で区切る)
        - 書き言葉として読める硬さに整える
        - 挨拶文・署名・宛名は発話に含まれていない限り追加しない
        """,
        sortOrder: 30,
        isBuiltin: false
    )

    public static let memo = Mode(
        id: "builtin.memo",
        name: "Memo",
        bundleIDs: [
            "com.apple.Notes",
            "md.obsidian",
            "com.electron.logseq",
            "net.shinyfrog.bear",
            "com.apple.Stickies",
        ],
        prompt: """
        思考のメモとして整形してください。

        - 結論が出ていない話を、無理にまとめたり言い切ったりしない
        - 話題が切り替わったら箇条書き(- )に分けて構造化する
        - 確信度を表す言葉(たぶん、〜かも)は残す。断定に書き換えない
        - 思考の順序を入れ替えない
        """,
        sortOrder: 40,
        isBuiltin: false
    )

    public static let code = Mode(
        id: "builtin.code",
        name: "Commit / PR",
        bundleIDs: [
            "com.github.GitHubClient",
            "com.sublimemerge",
            "com.fournova.Tower3",
        ],
        prompt: """
        コミットメッセージや PR 説明として整形してください。

        - 1 行目は要点を 50 文字程度で言い切る。句点は付けない
        - 詳細があれば空行を挟み、本文として「なぜそう変更したか」を書く
        - 体言止めまたは「〜する」の常体に統一する
        - 技術用語・識別子は正確な表記にする
        """,
        sortOrder: 50,
        isBuiltin: false
    )
}
