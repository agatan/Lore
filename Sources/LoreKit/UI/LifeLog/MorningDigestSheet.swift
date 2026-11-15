import SwiftUI

/// Yesterday's digest, shown once on the first open of the Life Log after it was made.
struct MorningDigestSheet: View {
    var env: AppEnvironment
    var digest: GeneratedNote

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("昨日のまとめ")
                    .font(.system(size: LoreTheme.TextSize.title, weight: .semibold))
                if let date = LifeLogDateKey.date(from: digest.scope.day) {
                    Text(date.loreFormatted(.dateTime.month(.wide).day().weekday(.wide)))
                        .font(LoreTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                GeneratedNoteView(env: env, subject: .day(digest.scope.day), style: .readOnly(digest))
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("life-log.morning-digest.close")
                Button("昨日を開く") {
                    let day = digest.scope.day
                    dismiss()
                    Task { await env.showLifeLogDigest(day: day) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("life-log.morning-digest.open")
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("life-log.morning-digest")
    }
}
