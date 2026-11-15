import SwiftUI

/// The inspector content for the event selected in the timeline. The header comes from the snapshot, so it is
/// there at once. The body follows `selection.load`.
struct EventDetailsInspector: View {
    var selection: EventSelection
    var onClose: () -> Void

    static let descriptionMaxLines = 8
    static let descriptionMaxCharacters = 400

    @Environment(\.openURL) private var openURL
    @State private var showsFullDescription = false

    private var event: CalendarEventSnapshot { selection.event }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onClose) { Label("概要", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("life-log.event-details.close")
                header
                switch selection.load {
                case .loading:
                    EmptyView()
                case .unavailable:
                    unavailable
                case .loaded(let details):
                    loaded(details)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("life-log.event-details")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: event.title)
                .font(.system(size: LoreTheme.TextSize.title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("life-log.event-details.title")
            timeText
                .font(.system(size: LoreTheme.TextSize.body).monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(verbatim: event.calendarTitle)
                if case .loaded(let details) = selection.load, details.isCanceled {
                    Text("キャンセル済み")
                        .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold))
                        .foregroundStyle(LoreTheme.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(LoreTheme.danger.opacity(0.14), in: Capsule())
                }
            }
            .font(.system(size: LoreTheme.TextSize.caption))
            .foregroundStyle(.secondary)
        }
    }

    private var timeText: Text {
        if event.isAllDay { return Text("終日") }
        let start = event.startsAt.loreFormatted(date: .omitted, time: .shortened)
        let end = event.endsAt.loreFormatted(date: .omitted, time: .shortened)
        return Text(verbatim: "\(start)–\(end)")
    }

    // MARK: Unavailable

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("予定の詳細を読み込めません", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: LoreTheme.TextSize.body, weight: .semibold))
            Text("カレンダーへのアクセスが許可されていないか、この予定がカレンダーに見つかりません。Loreに保存されている情報だけを表示しています。")
                .font(.system(size: LoreTheme.TextSize.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let own = ownResponse {
                section("あなたの返答") { responseLabel(own) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("life-log.event-details.unavailable")
    }

    /// The user's own response from the snapshot. Nil when the event has no invitation.
    private var ownResponse: AttendeeResponse? {
        event.participationStatus == .none ? nil : AttendeeResponse(event.participationStatus)
    }

    // MARK: Loaded

    @ViewBuilder
    private func loaded(_ details: CalendarEventDetails) -> some View {
        let guests = EventGuestList(details.attendees)
        if let link = details.conferenceLink { joinRow(link) }
        if let location = details.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            section("場所") {
                linkedText(location, size: LoreTheme.TextSize.body)
                    .accessibilityIdentifier("life-log.event-details.location")
            }
        }
        if let notes = details.notes {
            let text = EventDescriptionText.plainText(from: notes)
            if !text.isEmpty { descriptionSection(text) }
        }
        if let organizer = details.organizer {
            section("主催者") {
                Text(verbatim: Self.displayName(organizer))
                    .font(.system(size: LoreTheme.TextSize.body))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("life-log.event-details.organizer")
            }
        }
        if !guests.people.isEmpty { guestSection(guests) }
        if !guests.rooms.isEmpty {
            section("会議室") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(guests.rooms.enumerated()), id: \.offset) { _, room in attendeeRow(room) }
                }
                .accessibilityIdentifier("life-log.event-details.rooms")
            }
        }
    }

    private func joinRow(_ link: ConferenceLink) -> some View {
        HStack(spacing: 10) {
            Button { openURL(link.url) } label: { Label("参加", systemImage: "video.fill") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("life-log.event-details.join")
            Text(verbatim: Self.providerName(link.provider))
                .font(.system(size: LoreTheme.TextSize.callout))
                .foregroundStyle(.secondary)
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        let preview = EventDescriptionText.preview(text, maxLines: Self.descriptionMaxLines, maxCharacters: Self.descriptionMaxCharacters)
        let shown = showsFullDescription || !preview.isCut ? text : preview.text
        return section("説明") {
            VStack(alignment: .leading, spacing: 6) {
                linkedText(shown, size: LoreTheme.TextSize.body)
                    .accessibilityIdentifier("life-log.event-details.description")
                if preview.isCut {
                    Button { showsFullDescription.toggle() } label: {
                        Text(showsFullDescription ? "表示を減らす" : "続きを表示")
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("life-log.event-details.description-toggle")
                }
            }
        }
    }

    private func guestSection(_ guests: EventGuestList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("参加者 \(guests.people.count)人")
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
            counts(guests)
                .font(.system(size: LoreTheme.TextSize.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("life-log.event-details.guest-counts")
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(guests.people.enumerated()), id: \.offset) { _, guest in attendeeRow(guest) }
            }
            .accessibilityIdentifier("life-log.event-details.guests")
        }
    }

    private func counts(_ guests: EventGuestList) -> Text {
        var result = Text(verbatim: "")
        for (index, entry) in guests.counts.enumerated() {
            if index > 0 { result = result + Text(verbatim: " · ") }
            result = result + Self.responseName(entry.response) + Text(verbatim: " \(entry.count)")
        }
        return result
    }

    private func attendeeRow(_ attendee: CalendarAttendee) -> some View {
        let response = AttendeeResponse(attendee.status)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.responseSymbol(response))
                .font(.system(size: LoreTheme.TextSize.body))
                .foregroundStyle(Self.responseTint(response))
                .frame(width: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: Self.displayName(attendee))
                        .font(.system(size: LoreTheme.TextSize.body))
                        .lineLimit(2)
                    if attendee.isCurrentUser {
                        Text("自分")
                            .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                if attendee.name != nil, let email = attendee.email {
                    Text(verbatim: email)
                        .font(.system(size: LoreTheme.TextSize.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Self.responseName(response)
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func responseLabel(_ response: AttendeeResponse) -> some View {
        Label {
            Self.responseName(response)
        } icon: {
            Image(systemName: Self.responseSymbol(response)).foregroundStyle(Self.responseTint(response))
        }
        .font(.system(size: LoreTheme.TextSize.body))
    }

    /// Plain text whose `http` and `https` addresses open in the default browser.
    private func linkedText(_ text: String, size: CGFloat) -> some View {
        var attributed = AttributedString(text)
        for link in EventDescriptionText.links(in: text) {
            if let range = Range(NSRange(link.range, in: text), in: attributed) { attributed[range].link = link.url }
        }
        return Text(attributed)
            .font(.system(size: size))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private static func displayName(_ attendee: CalendarAttendee) -> String {
        [attendee.name, attendee.email].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "—"
    }

    private static func providerName(_ provider: ConferenceProvider) -> String {
        switch provider {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .microsoftTeams: "Microsoft Teams"
        case .webex: "Webex"
        }
    }

    private static func responseName(_ response: AttendeeResponse) -> Text {
        switch response {
        case .accepted: Text("承諾")
        case .declined: Text("辞退")
        case .tentative: Text("未定")
        case .noResponse: Text("未回答")
        }
    }

    private static func responseSymbol(_ response: AttendeeResponse) -> String {
        switch response {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .noResponse: "circle.dashed"
        }
    }

    private static func responseTint(_ response: AttendeeResponse) -> Color {
        switch response {
        case .accepted: LoreTheme.success
        case .declined: LoreTheme.danger
        case .tentative: LoreTheme.warning
        case .noResponse: Color.secondary
        }
    }
}
