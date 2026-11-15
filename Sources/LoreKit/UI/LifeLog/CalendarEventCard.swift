import SwiftUI

/// 予定はtimelineの縦線上の輪と、件名の見出しで描く。開始時刻は左の時刻列に任せ、
/// 見出しの下には長さとcalendar名だけを置く。区間の長さは縦線の色が示す。
struct CalendarEventCard: View {
    var event: CalendarEventSnapshot
    var above: LifeLogTimelineLayout.Segment = .none
    var below: LifeLogTimelineLayout.Segment = .none
    var isCurrent = false
    var compact = false
    /// 「記録しない」の表示と操作。渡さないrowは印もmenuも出さない。
    var recording: Recording?

    struct Recording {
        var exclusions: LifeLogRecordingExclusions
        var setSkipped: (Bool) -> Void
    }
    /// The "Last time" row of a repeating event. Shown until the event ends.
    var lastTime: LastTime?

    struct LastTime {
        var value: EventLastTime
        var open: () -> Void
        var openMemo: (LifeLogMemo) -> Void
    }
    /// The AI notes and the "do not send to AI" toggle. Only the main window passes it.
    var ai: AI?
    /// Shows the event in the inspector. Only the main window passes it.
    var onSelect: (() -> Void)?
    var isSelected = false
    /// "Join" for the meeting to join next. Only the event pinned in the mini window passes it.
    var join: (() -> Void)?

    struct AI {
        var notes: AnyView
        var isExcluded: Bool
        var isCalendarExcluded: Bool
        var setExcluded: (Bool) -> Void
    }

    /// "Open in Calendar" and "Open in Google Calendar". Only the main window passes it.
    var opening: Opening?

    struct Opening {
        var details: () async -> CalendarEventDetails?
    }

    @State private var googleCalendarURL: URL?
    @Environment(\.openURL) private var openURL

    private var titleSize: CGFloat { compact ? LoreTheme.TextSize.callout : LoreTheme.TextSize.reading }

    var body: some View {
        TimelineRowFrame(
            time: event.isAllDay ? Text("終日") : Text(event.startsAt.loreFormatted(date: .omitted, time: .shortened)),
            node: .event,
            nodeLabel: "予定",
            above: above,
            below: below,
            topPadding: compact ? 8 : 14,
            bottomPadding: compact ? 5 : 8,
            firstLineCenter: titleSize * 0.62,
            compact: compact
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(event.title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
                        .accessibilityAction { onSelect?() }
                        .accessibilityIdentifier("life-log.event-select-\(event.id)")
                    if isCurrent {
                        tag("いま", color: LoreTheme.event)
                    }
                    if event.participationStatus == .pending {
                        tag("未回答", color: LoreTheme.warning)
                            .accessibilityIdentifier("life-log.event-no-response-\(event.id)")
                    }
                    if recording?.exclusions.excludes(event) == true {
                        tag("記録しない", color: LoreTheme.recording)
                            .accessibilityIdentifier("life-log.event-not-recorded-\(event.id)")
                    }
                    if let join {
                        Spacer(minLength: 0)
                        MeetingJoinButton(accessibilityIdentifier: "life-log-mini.current-event.join", action: join)
                    }
                }
                detail
                    .font(LoreTheme.captionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let lastTime {
                    TimelineView(.explicit([event.endsAt])) { _ in
                        if event.endsAt > Date() { lastTimeRow(lastTime) }
                    }
                }
                if let ai { ai.notes }
            }
            .padding(.leading, compact ? 4 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous)
                        .fill(LoreTheme.event.opacity(0.14))
                        .padding(.vertical, -4)
                        .padding(.trailing, -6)
                }
            }
        }
        .padding(.trailing, compact ? 12 : 8)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .onTapGesture { onSelect?() }
        .contextMenu {
            openingMenu
            recordingMenu
            aiMenu
        }
        .task(id: opening == nil ? nil : event) {
            googleCalendarURL = await opening?.details()?.googleCalendarURL
        }
    }

    private func lastTimeRow(_ lastTime: LastTime) -> some View {
        let prefix = "life-log.event-last-time-\(event.id)"
        let day = LifeLogDateKey.date(from: lastTime.value.previous.occurrence.day)
            .map { $0.loreFormatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)) } ?? lastTime.value.previous.occurrence.day
        return VStack(alignment: .leading, spacing: 2) {
            Button(action: lastTime.open) {
                Label {
                    Text("前回") + Text(verbatim: " · \(day)")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            .buttonStyle(.link)
            .help("前回の記録を開く")
            .accessibilityIdentifier(prefix)
            ForEach(Array(lastTime.value.followUps.enumerated()), id: \.offset) { index, item in
                Text(verbatim: "· \(item.text)")
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .accessibilityIdentifier("\(prefix).item-\(index)")
            }
            ForEach(Array(lastTime.value.memos.enumerated()), id: \.element.id) { index, memo in
                Button { lastTime.openMemo(memo) } label: {
                    Label {
                        Text(verbatim: memo.text)
                            .lineLimit(compact ? 1 : 2)
                            .multilineTextAlignment(.leading)
                    } icon: {
                        Image(systemName: "note.text")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("前回のメモを開く")
                .accessibilityIdentifier("\(prefix).memo-\(index)")
            }
        }
        .font(LoreTheme.captionFont)
        .padding(.top, 3)
    }

    private func tag(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var openingMenu: some View {
        if opening != nil {
            if let url = CalendarEventLink.calendarApp(eventID: event.id) {
                Button("カレンダーで開く") { openURL(url) }
                    .accessibilityIdentifier("life-log.event.open-calendar")
            }
            if let googleCalendarURL {
                Button("Googleカレンダーで開く") { openURL(googleCalendarURL) }
                    .accessibilityIdentifier("life-log.event.open-google-calendar")
            }
            Divider()
        }
    }

    /// 終わっていない、時刻のある予定だけ。カレンダー単位の指定は設定で外す。
    @ViewBuilder
    private var recordingMenu: some View {
        if let recording, !event.isAllDay, event.endsAt > Date() {
            if recording.exclusions.isSkipped(event) {
                Button("この予定を記録する") { recording.setSkipped(false) }
                    .accessibilityIdentifier("life-log.event.record")
            } else if !recording.exclusions.excludes(event) {
                Button("この予定を記録しない") { recording.setSkipped(true) }
                    .accessibilityIdentifier("life-log.event.do-not-record")
            }
        }
    }

    @ViewBuilder
    private var aiMenu: some View {
        if let ai {
            if ai.isCalendarExcluded {
                Button("このカレンダーはAIに送らない設定です") {}.disabled(true)
            } else {
                Button(ai.isExcluded ? "AIへの送信を許可" : "AIに送らない") { ai.setExcluded(!ai.isExcluded) }
                    .accessibilityIdentifier("life-log.event.ai-exclusion")
            }
        }
    }

    private var detail: Text {
        guard !event.isAllDay else { return Text(verbatim: event.calendarTitle) }
        return Self.durationText(event.endsAt.timeIntervalSince(event.startsAt)) + Text(verbatim: " · \(event.calendarTitle)")
    }

    /// 「30分」「1時間」「1時間30分」。表示言語の書式で返す。
    static func durationText(_ interval: TimeInterval) -> Text {
        let minutes = max(0, Int((interval / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return Text("\(rest)分") }
        return rest == 0 ? Text("\(hours)時間") : Text("\(hours)時間\(rest)分")
    }
}

/// The event in progress and the meeting to join next, pinned outside the mini window's scroll area.
/// It redraws only when an event starts or ends or the countdown changes.
struct CurrentCalendarEventStrip: View {
    /// Today's events. The strip never follows the main window's selected day.
    var events: [CalendarEventSnapshot]
    var meetings: UpcomingMeetings
    var recording: (CalendarEventSnapshot) -> CalendarEventCard.Recording?
    var lastTime: (CalendarEventSnapshot) -> CalendarEventCard.LastTime?
    var join: (JoinableMeeting) -> Void

    var body: some View {
        UpcomingMeetingsTimeline(meetings: meetings, extraBoundaries: events.flatMap { [$0.startsAt, $0.endsAt] }) { now, entries in
            let current = events.timedEventInProgress(at: now)
            let next = entries.first
            let nextIsCurrent = next.map { $0.meeting.event.id == current?.id && $0.meeting.event.startsAt == current?.startsAt } ?? false
            VStack(spacing: 0) {
                if let next, !nextIsCurrent {
                    MeetingJoinRow(entry: next, accessibilityPrefix: "life-log-mini.meeting") { join(next.meeting) }
                        .padding(.leading, 16)
                        .padding(.trailing, 12)
                        .padding(.vertical, 6)
                }
                if let current {
                    CalendarEventCard(
                        event: current, isCurrent: true, compact: true,
                        recording: recording(current), lastTime: lastTime(current),
                        join: nextIsCurrent ? next.map { entry in { join(entry.meeting) } } : nil
                    )
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

extension AppEnvironment {
    /// Timelineの予定rowへ渡す「記録しない」の表示と操作。
    func eventRecording(_ event: CalendarEventSnapshot) -> CalendarEventCard.Recording {
        CalendarEventCard.Recording(exclusions: settings.lifeLogRecordingExclusions) { [weak self] skipped in
            self?.setLifeLogEventSkipped(skipped, event: event)
        }
    }

    func eventLastTime(_ event: CalendarEventSnapshot, in day: LifeLogDay) -> CalendarEventCard.LastTime? {
        guard let value = day.lastTime(
            for: event,
            recordingExclusions: settings.lifeLogRecordingExclusions,
            aiSettings: settings.lifeLogAI,
            aiExcludedEventIDs: lifeLogAI.excludedEventIDs
        ) else { return nil }
        return CalendarEventCard.LastTime(value: value, open: { [weak self] in
            Task { await self?.showLifeLogPreviousOccurrence(value.previous) }
        }, openMemo: { [weak self] memo in
            Task { await self?.showLifeLogMemo(memo) }
        })
    }
}
