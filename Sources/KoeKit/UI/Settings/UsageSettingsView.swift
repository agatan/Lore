import Charts
import SwiftUI

/// APIコストだけに寄らず、Koeをどれくらい使い、端末に何が残っているかを一か所で見る。
struct UsageSettingsView: View {
    var env: AppEnvironment

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            overview
            recordingCard
            apiCard
            storageCard
        }
        .task { await env.reloadUsageStatistics() }
    }

    private var overview: some View {
        HStack(spacing: 10) {
            metricTile(
                title: "今日の記録",
                value: durationText(today.dictationSeconds + today.lifeLogSeconds),
                symbol: "waveform",
                tint: KoeTheme.accent
            )
            metricTile(
                title: "7日間のAPI",
                value: "\(week.reduce(0) { $0 + $1.dictationTokens + $1.lifeLogTokens }.formatted()) tokens",
                symbol: "sparkles",
                tint: KoeTheme.warning
            )
            metricTile(
                title: "ローカル保存",
                value: bytesText(env.appDataBytes),
                symbol: "internaldrive",
                tint: KoeTheme.success
            )
        }
        .accessibilityIdentifier("usage.overview")
    }

    private func metricTile(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.tint(tint.opacity(0.22)), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 62)
        .raisedGlass(cornerRadius: 16)
    }

    private var recordingCard: some View {
        SettingsCard(title: "記録時間", footnote: "音声入力の録音時間と、ライフログの実発話時間です。無音は含みません。") {
            Chart(week) { value in
                BarMark(
                    x: .value("日", value.label),
                    y: .value("時間", value.lifeLogSeconds / 3_600)
                )
                .foregroundStyle(by: .value("種類", "ライフログ"))
                .position(by: .value("種類", "ライフログ"))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                BarMark(
                    x: .value("日", value.label),
                    y: .value("時間", value.dictationSeconds / 3_600)
                )
                .foregroundStyle(by: .value("種類", "音声入力"))
                .position(by: .value("種類", "音声入力"))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .chartForegroundStyleScale([
                "ライフログ": KoeTheme.accent,
                "音声入力": KoeTheme.recording,
            ])
            .chartLegend(position: .top, alignment: .leading, spacing: 14)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(hours < 1 ? "\(Int(hours * 60))分" : String(format: "%.0fh", hours))
                        }
                    }
                }
            }
            .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 9.5)) } }
            .frame(height: 190)
        }
        .accessibilityIdentifier("usage.recording")
    }

    private var apiCard: some View {
        SettingsCard(title: "クラウドAI", footnote: "API応答に含まれる実測トークン数です。ローカルモデルは含みません。") {
            Chart(week) { value in
                BarMark(
                    x: .value("日", value.label),
                    y: .value("Tokens", value.lifeLogTokens)
                )
                .foregroundStyle(by: .value("用途", "ライフログ"))
                .position(by: .value("用途", "ライフログ"))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                BarMark(
                    x: .value("日", value.label),
                    y: .value("Tokens", value.dictationTokens)
                )
                .foregroundStyle(by: .value("用途", "音声入力"))
                .position(by: .value("用途", "音声入力"))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .chartForegroundStyleScale([
                "ライフログ": KoeTheme.accent,
                "音声入力": KoeTheme.recording,
            ])
            .chartLegend(position: .top, alignment: .leading, spacing: 14)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(tokens >= 1_000 ? String(format: "%.0fk", Double(tokens) / 1_000) : "\(tokens)")
                        }
                    }
                }
            }
            .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 9.5)) } }
            .frame(height: 190)

            HStack {
                apiSummary("音声入力", purpose: .dictation, tint: KoeTheme.recording)
                Divider().frame(height: 32)
                apiSummary("ライフログ", purpose: .lifeLog, tint: KoeTheme.accent)
            }
        }
        .accessibilityIdentifier("usage.api")
    }

    private func apiSummary(_ title: String, purpose: LlmPurpose, tint: Color) -> some View {
        let values = env.llmUsage(for: purpose).filter { usage in week.contains { $0.day == usage.day } }
        let tokens = values.reduce(0) { $0 + $1.totalTokens }
        let requests = values.reduce(0) { $0 + $1.requestCount }
        return HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).font(.system(size: 10.5, weight: .medium))
            Spacer()
            Text("\(tokens.formatted()) · \(requests)回")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var storageCard: some View {
        SettingsCard(title: "ストレージ", footnote: "Koeのアプリ用データです。ライフログ音声は設定した保持期間に従って削除されます。") {
            HStack(alignment: .firstTextBaseline) {
                Text(bytesText(env.appDataBytes))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("合計").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
            }
            GeometryReader { geometry in
                let audioWidth = env.appDataBytes > 0
                    ? geometry.size.width * CGFloat(min(1, Double(env.lifeLogAudioBytes) / Double(env.appDataBytes)))
                    : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.13))
                    Capsule().fill(KoeTheme.accent.gradient).frame(width: audioWidth)
                }
            }
            .frame(height: 9)
            HStack {
                storageLegend("ライフログ音声", bytes: env.lifeLogAudioBytes, tint: KoeTheme.accent)
                Spacer()
                storageLegend("履歴・設定", bytes: max(0, env.appDataBytes - env.lifeLogAudioBytes), tint: .secondary)
            }
        }
        .accessibilityIdentifier("usage.storage")
    }

    private func storageLegend(_ title: String, bytes: Int64, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(bytesText(bytes)).font(.system(size: 10.5, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }

    private struct DayValue: Identifiable {
        var id: String { day }
        let day: String
        let label: String
        let dictationSeconds: TimeInterval
        let lifeLogSeconds: TimeInterval
        let dictationTokens: Int
        let lifeLogTokens: Int
    }

    private var week: [DayValue] {
        let calendar = Calendar.current
        let dictationDuration = Dictionary(uniqueKeysWithValues: env.dailyDictationDuration.map { ($0.day, $0.seconds) })
        let lifeLogDuration = Dictionary(uniqueKeysWithValues: env.dailyLifeLogDuration.map { ($0.day, $0.seconds) })
        let dictationTokens = Dictionary(uniqueKeysWithValues: env.llmUsage(for: .dictation).map { ($0.day, $0.totalTokens) })
        let lifeLogTokens = Dictionary(uniqueKeysWithValues: env.llmUsage(for: .lifeLog).map { ($0.day, $0.totalTokens) })
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let day = LifeLogDateKey.string(for: date, calendar: calendar)
            return DayValue(
                day: day,
                label: calendar.isDateInToday(date) ? "今日" : date.formatted(.dateTime.weekday(.narrow)),
                dictationSeconds: dictationDuration[day] ?? 0,
                lifeLogSeconds: lifeLogDuration[day] ?? 0,
                dictationTokens: dictationTokens[day] ?? 0,
                lifeLogTokens: lifeLogTokens[day] ?? 0
            )
        }
    }

    private var today: DayValue {
        week.last ?? DayValue(day: "", label: "今日", dictationSeconds: 0, lifeLogSeconds: 0, dictationTokens: 0, lifeLogTokens: 0)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60)時間 \(minutes % 60)分" }
        return "\(minutes)分"
    }

    private func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
