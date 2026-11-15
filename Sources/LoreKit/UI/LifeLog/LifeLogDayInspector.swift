import SwiftUI

/// Main windowの右のinspector「この日」。上に量の要約、下に時刻の縦軸で見る一日の流れ。
///
/// Timelineが「何を話したか」を読む面なのに対し、ここは「いつ何があったか」を一目で掴む面にする。
/// Calendar appの日表示と同じく、予定はblock、記録は縦軸の脇の印で示す。
struct LifeLogDayInspector: View {
    var day: LifeLogDay
    var date: Date
    var onJump: (Date) -> Void
    var onShowEvent: (EventOccurrence) -> Void = { _ in }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }
    private var mapLayout: LifeLogDayMapLayout { LifeLogDayMapLayout(day: day, date: date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summary
            if !day.generatedNotes.isEmpty { aiNotes }
            // 過去日で予定も記録もなければ、空の目盛りは何も伝えないので出さない。
            // 今日は現在時刻の線が残りの時間を示すため、空でも出す。
            if isToday || !mapLayout.blocks.isEmpty || !mapLayout.marks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("時間ごとの記録")
                        .font(LoreTheme.sectionFont)
                        .foregroundStyle(.secondary)
                    LifeLogDayMap(layout: mapLayout, date: date, onJump: onJump)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("life-log.day-insights")
    }

    /// Events of the day that have AI notes. Selecting one moves the timeline to the event.
    private var aiNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AIノート", systemImage: "sparkles")
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
            ForEach(day.generatedNotes) { note in
                let title = day.event(of: note)?.title
                Button {
                    if case .event(let occurrence) = note.scope { onShowEvent(occurrence) }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: title ?? "—")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if !note.staleReasons.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(LoreTheme.warning)
                                .help(Text("内容が古い可能性があります"))
                        }
                        Text(verbatim: "\(note.sections.reduce(0) { $0 + $1.items.count })")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: LoreTheme.TextSize.body))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("life-log.inspector-ai-note-\(note.scope.eventID ?? note.id)")
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let value = LifeLogDaySummary(day: day)
        if value.utteranceCount + value.memoCount + value.dictationCount == 0 {
            // 0を並べても何も伝わらないため、記録がない日は一言だけにする。
            VStack(alignment: .leading, spacing: 4) {
                Text("話した時間")
                    .font(LoreTheme.sectionFont)
                    .foregroundStyle(.secondary)
                Text(isToday ? "まだ記録はありません" : "記録はありません")
                    .font(.system(size: LoreTheme.TextSize.headline, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        } else {
            filledSummary(value)
        }
    }

    private func filledSummary(_ value: LifeLogDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("話した時間")
                    .font(LoreTheme.sectionFont)
                    .foregroundStyle(.secondary)
                Self.spokenText(value.spokenDuration)
                    .font(.system(size: LoreTheme.TextSize.metric, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            HStack(spacing: 0) {
                count(value.utteranceCount, "発話", symbol: "waveform", tint: .secondary)
                count(value.memoCount, "メモ", symbol: "pencil", tint: LoreTheme.accent)
                count(value.dictationCount, "音声入力", symbol: "keyboard", tint: LoreTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func count(_ value: Int, _ label: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(value)")
                .font(.system(size: LoreTheme.TextSize.title, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? .tertiary : .primary)
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold))
                    .foregroundStyle(tint)
                Text(LocalizedStringKey(label))
                    .font(.system(size: LoreTheme.TextSize.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「0分」「12分」「1時間4分」。1分未満は話していれば「1分未満」。
    static func spokenText(_ seconds: TimeInterval) -> Text {
        if seconds > 0 && seconds < 60 { return Text("1分未満") }
        return CalendarEventCard.durationText(seconds)
    }
}

/// 時刻の縦軸に、予定block・記録の印・現在時刻を描く。
struct LifeLogDayMap: View {
    var layout: LifeLogDayMapLayout
    var date: Date
    var onJump: (Date) -> Void

    @State private var hoverY: CGFloat?

    private let labelWidth: CGFloat = 24
    private let markLane: CGFloat = 10
    private let laneGap: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let eventsX = labelWidth + 6 + markLane + laneGap
            ZStack(alignment: .topLeading) {
                grid(size: size)
                marks(size: size)
                ForEach(layout.blocks) { block in
                    eventBlock(block, size: size, originX: eventsX)
                }
                nowLine(size: size)
                if let hoverY { hoverGuide(y: hoverY, size: size) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): hoverY = min(max(0, location.y), size.height)
                case .ended: hoverY = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                onJump(layout.date(at: Double(location.y / max(1, size.height))))
            }
        }
        .frame(minHeight: CGFloat(layout.hourCount) * 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("life-log.day-map")
    }

    private func y(_ date: Date, height: CGFloat) -> CGFloat {
        CGFloat(layout.position(of: date)) * height
    }

    /// 時刻の目盛り。1時間の高さが詰まる日は2〜3時間おきに数字を置く。
    private func grid(size: CGSize) -> some View {
        let hourHeight = size.height / CGFloat(max(1, layout.hourCount))
        let stride = hourHeight >= 22 ? 1 : (hourHeight >= 12 ? 2 : 3)
        return ZStack(alignment: .topLeading) {
            ForEach(layout.startHour...layout.endHour, id: \.self) { hour in
                let lineY = CGFloat(hour - layout.startHour) * hourHeight
                Rectangle()
                    .fill(Color.primary.opacity(hour % 6 == 0 ? 0.1 : 0.055))
                    .frame(width: size.width - labelWidth - 6, height: 1)
                    .offset(x: labelWidth + 6, y: lineY)
                if hour % stride == 0 {
                    Text(verbatim: "\(hour)")
                        .font(.system(size: LoreTheme.TextSize.micro).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(y: lineY - 6.5)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 発話は長さに応じた細い棒、memoと音声入力は点で、縦軸のすぐ脇に置く。
    private func marks(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let x = labelWidth + 6
            for mark in layout.marks {
                let top = y(mark.start, height: canvasSize.height)
                switch mark.kind {
                case .utterance:
                    let bottom = max(top + 4, y(mark.end, height: canvasSize.height))
                    let rect = CGRect(x: x + 1.5, y: top, width: 5, height: bottom - top)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(LoreTheme.accent.opacity(0.75)))
                case .dictation:
                    let rect = CGRect(x: x + 1.5, y: top - 2.5, width: 5, height: 5)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(LoreTheme.accent))
                case .memo:
                    let rect = CGRect(x: x + 1, y: top - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: rect), with: .color(LoreTheme.accent))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func eventBlock(_ block: LifeLogDayMapLayout.Block, size: CGSize, originX: CGFloat) -> some View {
        let laneWidth = size.width - originX
        let columnWidth = laneWidth / CGFloat(block.columnCount)
        let top = y(block.event.startsAt, height: size.height)
        let height = max(14, y(block.event.endsAt, height: size.height) - top - 1.5)
        let isNow = Calendar.current.isDateInToday(date) && block.event.contains(Date())
        return Button { onJump(block.event.startsAt) } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(LoreTheme.event)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(block.event.title)
                        .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
                        .lineLimit(height >= 40 ? 2 : 1)
                    if height >= 30 {
                        Text(verbatim: "\(block.event.startsAt.loreFormatted(date: .omitted, time: .shortened))–\(block.event.endsAt.loreFormatted(date: .omitted, time: .shortened))")
                            .font(.system(size: LoreTheme.TextSize.micro).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, height >= 22 ? 3 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: height >= 22 ? .topLeading : .leading)
            }
            .background(LoreTheme.event.opacity(isNow ? 0.26 : 0.15))
            .clipShape(RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: columnWidth - (block.columnCount > 1 ? 2 : 0), height: height)
        .offset(x: originX + CGFloat(block.column) * columnWidth, y: top + 0.75)
        .help(block.event.title)
        .accessibilityLabel(Text(verbatim: "\(block.event.title)、\(block.event.startsAt.loreFormatted(date: .omitted, time: .shortened))"))
        .accessibilityIdentifier("life-log.calendar-event-\(block.event.id)")
    }

    @ViewBuilder
    private func nowLine(size: CGSize) -> some View {
        if Calendar.current.isDateInToday(date) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let position = layout.position(of: context.date)
                if position > 0 && position < 1 {
                    let lineY = CGFloat(position) * size.height
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(LoreTheme.recording)
                            .frame(width: size.width - labelWidth, height: 1.5)
                            .offset(x: labelWidth + 2, y: lineY - 0.75)
                        Circle()
                            .fill(LoreTheme.recording)
                            .frame(width: 7, height: 7)
                            .offset(x: labelWidth - 1, y: lineY - 3.5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func hoverGuide(y lineY: CGFloat, size: CGSize) -> some View {
        let time = layout.date(at: Double(lineY / max(1, size.height)))
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.primary.opacity(0.25))
                .frame(width: size.width - labelWidth - 6, height: 1)
                .offset(x: labelWidth + 6, y: lineY)
            Text(time.loreFormatted(date: .omitted, time: .shortened))
                .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.regularMaterial, in: Capsule())
                .offset(x: max(0, size.width - 44), y: lineY - 17)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
