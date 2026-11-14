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
        Format the text so it reads naturally wherever it is pasted.

        - Split separate topics into paragraphs with a blank line.
        - Use "- " bullets only when the speaker lists several distinct items. Never break one thought into steps.
        - Keep the speaker's tone and politeness. Do not make it more formal (no 「〜させていただきます」 rewrites).
        - No headings or bold unless the speaker asked for them.
        - A one-sentence utterance stays one sentence.
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
        Format the text as a chat message.

        - Keep the conversational distance. Do not stiffen it into written prose.
        - Keep it short: one to three sentences, with line breaks only between ideas.
        - Keep です/ます if spoken, but do not add stock courtesy phrases (お忙しいところ恐れ入りますが, "Hope you're well").
        - No emoji or decoration unless spoken.
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
        Format the text as the body of an email or document.

        - In Japanese, use です/ます consistently.
        - Break paragraphs at each change of topic, with a blank line.
        - Make it read as written prose, not as speech.
        - Do not add greetings, signatures, or recipients unless spoken.
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
        Format the text as a note to self.

        - Do not resolve or conclude what the speaker left open.
        - Split topic changes into "- " bullets.
        - Keep hedges (たぶん, 〜かも, maybe). Do not turn them into certainty.
        - Keep the order of thoughts.
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
        Format the text as a commit message or pull request description.

        - First line: the gist in about 50 characters, no trailing period.
        - If there is more, add a blank line and explain why the change was made.
        - In Japanese, use plain form (常体) or noun endings. In English, use the imperative mood ("Fix", "Add").
        - Spell technical terms and identifiers exactly.
        """,
        sortOrder: 50,
        isBuiltin: false
    )
}
