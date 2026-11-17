import Foundation

public enum LifeLogProcessingState: String, Codable, Sendable, CaseIterable {
    case captured
    case transcribed
    case segmented
    case extracted
    case failed
}

public struct LifeLogAudioChunk: Identifiable, Codable, Sendable, Hashable {
    /// UI用の正規化levelで約-50 dBFSに相当する保存chunkの絶対下限。
    public static let minimumTranscriptionPeakLevel: Float = 1 / 6

    public var id: String
    public var captureStartedAt: Date
    public var captureEndedAt: Date
    public var localPath: String
    public var transcriptionState: LifeLogProcessingState
    public var processingState: LifeLogProcessingState
    public var failureReason: String?
    /// 0...1 の正規化入力レベル。旧データは nil として安全側に再処理する。
    public var peakLevel: Float?

    public init(id: String = UUID().uuidString, captureStartedAt: Date, captureEndedAt: Date,
                localPath: String, transcriptionState: LifeLogProcessingState = .captured,
                processingState: LifeLogProcessingState = .captured, failureReason: String? = nil,
                peakLevel: Float? = nil) {
        self.id = id
        self.captureStartedAt = captureStartedAt
        self.captureEndedAt = captureEndedAt
        self.localPath = localPath
        self.transcriptionState = transcriptionState
        self.processingState = processingState
        self.failureReason = failureReason
        self.peakLevel = peakLevel
    }

    public var isTranscriptionCandidate: Bool {
        guard captureEndedAt.timeIntervalSince(captureStartedAt) >= 1 else { return false }
        return peakLevel.map { $0 >= Self.minimumTranscriptionPeakLevel } ?? true
    }
}

public struct CalendarEventSnapshot: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var externalIdentifier: String?
    public var title: String
    public var startsAt: Date
    public var endsAt: Date
    public var calendarTitle: String
    public var isAllDay: Bool
    public var participationStatus: CalendarParticipationStatus

    public init(id: String = UUID().uuidString, externalIdentifier: String? = nil, title: String,
                startsAt: Date, endsAt: Date, calendarTitle: String, isAllDay: Bool = false,
                participationStatus: CalendarParticipationStatus = .none) {
        self.id = id; self.externalIdentifier = externalIdentifier; self.title = title
        self.startsAt = startsAt; self.endsAt = endsAt; self.calendarTitle = calendarTitle; self.isAllDay = isAllDay
        self.participationStatus = participationStatus
    }

    public func contains(_ date: Date, tolerance: TimeInterval = 0) -> Bool {
        startsAt.addingTimeInterval(-tolerance) <= date && date < endsAt.addingTimeInterval(tolerance)
    }
}

extension Sequence where Element == CalendarEventSnapshot {
    /// `date`に進行中の、時刻のある予定。重なる場合は先に始まったもの。
    public func timedEventInProgress(at date: Date) -> CalendarEventSnapshot? {
        filter { !$0.isAllDay && $0.contains(date) }.min { $0.startsAt < $1.startsAt }
    }
}

/// Calendarから読み取った参加状態。Loreからは変更しない。
public enum CalendarParticipationStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case pending
    case accepted
    case declined
    case tentative
    case unknown

    /// RSVPが存在しない自分の予定と、参加済みの予定だけを利用する。
    public var isParticipating: Bool { self == .none || self == .accepted }

    /// 「参加する予定だけ」がオンのとき、画面・エクスポート・自動化に出す予定。
    /// 未回答の招待は、利用者が見つけて返答できるよう含める。辞退・仮承諾・不明は隠す。
    public var isShownWhenAttendingOnly: Bool { isParticipating || self == .pending }
}

public struct LifeLogUtterance: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var text: String
    /// 他のMacから同期した発話は、このMacに保存audioを持たないためnil。
    public var audioChunkID: String?
    public var calendarEventID: String?

    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date, text: String,
                audioChunkID: String?, calendarEventID: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.text = text
        self.audioChunkID = audioChunkID; self.calendarEventID = calendarEventID
    }
}

/// 音声入力履歴をライフログ上へ投影した項目。履歴が正本なので二重保存しない。
public struct LifeLogDictation: Identifiable, Sendable, Hashable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var text: String

    public init(id: String, startedAt: Date, endedAt: Date, text: String) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.text = text
    }
}

/// 同じマイク区間を二つの認識経路が文字化した場合、成功した音声入力を正本にする。
/// Raw audioと保存済みutteranceは回復用に残し、利用者へ返すprojectionだけを一意にする。
public enum LifeLogSpeechProjection {
    public static func visibleUtterances(
        _ utterances: [LifeLogUtterance],
        preferring dictations: [LifeLogDictation]
    ) -> [LifeLogUtterance] {
        guard !utterances.isEmpty, !dictations.isEmpty else { return utterances }
        let utteranceIndices = utterances.indices.sorted { utterances[$0].startedAt < utterances[$1].startedAt }
        let sortedDictations = dictations.sorted { $0.startedAt < $1.startedAt }
        var hidden = Set<Int>()
        var firstCandidate = 0
        for index in utteranceIndices {
            let utterance = utterances[index]
            while firstCandidate < sortedDictations.count,
                  sortedDictations[firstCandidate].endedAt <= utterance.startedAt {
                firstCandidate += 1
            }
            var candidate = firstCandidate
            while candidate < sortedDictations.count,
                  sortedDictations[candidate].startedAt < utterance.endedAt {
                if utterance.startedAt < sortedDictations[candidate].endedAt {
                    hidden.insert(index)
                    break
                }
                candidate += 1
            }
        }
        return utterances.indices.compactMap { hidden.contains($0) ? nil : utterances[$0] }
    }
}

/// 利用者がタイムラインへ直接残すテキスト。音声認識結果とは混同しない。
public struct LifeLogMemo: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var createdAt: Date
    public var text: String

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

public struct LifeLogDay: Sendable {
    public var utterances: [LifeLogUtterance]
    public var dictations: [LifeLogDictation]
    public var memos: [LifeLogMemo]
    public var calendarEvents: [CalendarEventSnapshot]
    /// AI notes whose scope is this day.
    public var generatedNotes: [GeneratedNote]
    /// The latest earlier occurrence with recorded speech, keyed by the occurrence it precedes.
    public var previousOccurrences: [EventOccurrence: PreviousEventOccurrence]
    /// Stored notes of this day or of an earlier occurrence that could not be decoded. Notes are regenerable
    /// output, so they are set aside here instead of hiding the records of the day.
    public var unreadableNotes: [UnreadableGeneratedNote]

    public init(utterances: [LifeLogUtterance] = [], dictations: [LifeLogDictation] = [], memos: [LifeLogMemo] = [],
                calendarEvents: [CalendarEventSnapshot] = [], generatedNotes: [GeneratedNote] = [],
                previousOccurrences: [EventOccurrence: PreviousEventOccurrence] = [:],
                unreadableNotes: [UnreadableGeneratedNote] = []) {
        self.utterances = utterances
        self.dictations = dictations
        self.memos = memos
        self.calendarEvents = calendarEvents
        self.generatedNotes = generatedNotes
        self.previousOccurrences = previousOccurrences
        self.unreadableNotes = unreadableNotes
    }

    /// What the "Last time" row of an event shows, or nil when it shows nothing.
    public func lastTime(
        for event: CalendarEventSnapshot,
        recordingExclusions: LifeLogRecordingExclusions,
        aiSettings: LifeLogAISettings,
        aiExcludedEventIDs: Set<String>
    ) -> EventLastTime? {
        guard !event.isAllDay, !recordingExclusions.excludes(event),
              let previous = previousOccurrences[EventOccurrence(event)] else { return nil }
        // Memos are the user's own words and are sent nowhere, so an AI exclusion does not hide them.
        let memos = Array(previous.memos.suffix(EventLastTime.maximumMemos))
        guard let notes = previous.notes, !aiSettings.excludes(event, excludedEventIDs: aiExcludedEventIDs) else {
            return EventLastTime(previous: previous, followUps: [], memos: memos)
        }
        let followUps = notes.items(.commitments) + notes.items(.requests)
        return EventLastTime(previous: previous, followUps: Array(followUps.prefix(EventLastTime.maximumFollowUps)), memos: memos)
    }

    public func eventNotes(for event: CalendarEventSnapshot, calendar: Calendar = .current) -> GeneratedNote? {
        let scope = GeneratedNoteScope.event(EventOccurrence(event, calendar: calendar))
        return generatedNotes.first { $0.kind == .eventNotes && $0.scope == scope }
    }

    public var dailyDigest: GeneratedNote? { generatedNotes.first { $0.kind == .dailyDigest } }

    public func event(of note: GeneratedNote, calendar: Calendar = .current) -> CalendarEventSnapshot? {
        calendarEvents.first { .event(EventOccurrence($0, calendar: calendar)) == note.scope }
    }
}

/// An earlier occurrence of a repeating event.
public struct PreviousEventOccurrence: Sendable, Hashable {
    public var occurrence: EventOccurrence
    public var firstUtteranceID: String
    public var notes: GeneratedNote?
    /// Memos created within the occurrence's start and end, oldest first.
    public var memos: [LifeLogMemo]

    public init(occurrence: EventOccurrence, firstUtteranceID: String, notes: GeneratedNote? = nil, memos: [LifeLogMemo] = []) {
        self.occurrence = occurrence
        self.firstUtteranceID = firstUtteranceID
        self.notes = notes
        self.memos = memos
    }
}

public struct EventLastTime: Sendable, Hashable {
    public static let maximumFollowUps = 3
    public static let maximumMemos = 3

    public var previous: PreviousEventOccurrence
    /// What the user took on, then what the user asked others for, in the earlier occurrence's notes.
    public var followUps: [GeneratedNoteItem]
    /// The newest memos of the earlier occurrence, oldest first.
    public var memos: [LifeLogMemo]
}

/// 月間カレンダーに描画する日ごとの密度。数値そのものはUIへ表示せず、
/// 予定と発話を独立した視覚チャンネルへ変換する。
public struct LifeLogDayActivity: Sendable, Equatable {
    public var calendarEventCount: Int
    public var capturedDuration: TimeInterval

    public init(calendarEventCount: Int = 0, capturedDuration: TimeInterval = 0) {
        self.calendarEventCount = calendarEventCount
        self.capturedDuration = capturedDuration
    }

    public var eventIntensity: Double { min(1, Double(calendarEventCount) / 4) }
    public var voiceIntensity: Double { min(1, capturedDuration / (60 * 45)) }
    public var isEmpty: Bool { calendarEventCount == 0 && capturedDuration == 0 }
}

public struct LifeLogSearchResult: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case utterance
        case dictation
        case memo
        /// Event notes and daily digests written by Life Log AI.
        case generated

        public var displayName: String {
            switch self {
            case .utterance: "発話"
            case .dictation: "音声入力"
            case .memo: "メモ"
            case .generated: "AIが生成"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var occurredAt: Date
    public var day: String
    /// The item of `day` that selecting the result moves the timeline to.
    public var timelineItemID: String

    public init(id: String, kind: Kind, text: String, occurredAt: Date, day: String, timelineItemID: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.occurredAt = occurredAt
        self.day = day
        self.timelineItemID = timelineItemID
    }
}

public enum LifeLogDateKey {
    public static func string(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func date(from value: String, calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
