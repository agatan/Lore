import Foundation

public enum LifeLogProcessingState: String, Codable, Sendable, CaseIterable {
    case captured
    case transcribed
    case segmented
    case extracted
    case failed
}

public struct LifeLogAudioChunk: Identifiable, Codable, Sendable, Hashable {
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
        captureEndedAt.timeIntervalSince(captureStartedAt) >= 1
            && (peakLevel == nil || peakLevel! >= AdaptiveSpeechSegmenter.speechLevelThreshold)
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

/// Calendarから読み取った参加状態。Koeからは変更しない。
public enum CalendarParticipationStatus: String, Codable, Sendable, Hashable {
    case none
    case pending
    case accepted
    case declined
    case tentative
    case unknown

    /// RSVPが存在しない自分の予定と、参加済みの予定だけを利用する。
    public var isParticipating: Bool { self == .none || self == .accepted }
}

public struct LifeLogUtterance: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var text: String
    public var audioChunkID: String
    public var calendarEventID: String?
    public var conversationID: String?

    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date, text: String,
                audioChunkID: String, calendarEventID: String? = nil, conversationID: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.text = text
        self.audioChunkID = audioChunkID; self.calendarEventID = calendarEventID; self.conversationID = conversationID
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

public struct LifeLogConversation: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var calendarEventID: String?
    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date, calendarEventID: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.calendarEventID = calendarEventID
    }
}

public struct LifeLogTodo: Identifiable, Codable, Sendable, Hashable {
    /// LLM出力は必ず draft。利用者が確認したものだけが open になる。
    public enum Status: String, Codable, Sendable { case draft, open, completed }
    public var id: String
    public var title: String
    public var status: Status
    public var createdAt: Date
    public var completedAt: Date?
    public var dueAt: Date?
    public var sourceConversationID: String?
    public var sourceUtteranceIDs: [String]
    public var sourceMemoIDs: [String]
    public var confidence: Double?

    public init(id: String = UUID().uuidString, title: String, status: Status = .open,
                createdAt: Date = Date(), completedAt: Date? = nil, dueAt: Date? = nil, sourceConversationID: String? = nil,
                sourceUtteranceIDs: [String] = [], sourceMemoIDs: [String] = [], confidence: Double? = nil) {
        self.id = id; self.title = title; self.status = status; self.createdAt = createdAt
        self.completedAt = status == .completed ? (completedAt ?? createdAt) : nil
        self.dueAt = dueAt
        self.sourceConversationID = sourceConversationID; self.sourceUtteranceIDs = sourceUtteranceIDs
        self.sourceMemoIDs = sourceMemoIDs; self.confidence = confidence
    }

    /// 完了日時と状態を常に一緒に遷移させる。
    public mutating func transition(to status: Status, at date: Date = Date()) {
        self.status = status
        completedAt = status == .completed ? date : nil
    }
}

public struct DailySummary: Identifiable, Codable, Sendable, Hashable {
    public var id: String { day }
    public var day: String
    public var summary: String
    public var commitments: [String]
    public var topics: [String]
    public var calendarEventCount: Int
    public var capturedDurationSeconds: Int
    public var utteranceCount: Int
    public var summarizedThrough: Date
    public var isFinal: Bool
}

public struct LifeLogDay: Sendable {
    public var utterances: [LifeLogUtterance]
    public var dictations: [LifeLogDictation]
    public var memos: [LifeLogMemo]
    public var conversations: [LifeLogConversation]
    public var calendarEvents: [CalendarEventSnapshot]
    public var summary: DailySummary?

    public init(utterances: [LifeLogUtterance], dictations: [LifeLogDictation] = [], memos: [LifeLogMemo] = [],
                conversations: [LifeLogConversation], calendarEvents: [CalendarEventSnapshot],
                summary: DailySummary?) {
        self.utterances = utterances
        self.dictations = dictations
        self.memos = memos
        self.conversations = conversations
        self.calendarEvents = calendarEvents
        self.summary = summary
    }
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
        case todo
        case summary

        public var displayName: String {
            switch self {
            case .utterance: "発話"
            case .dictation: "音声入力"
            case .memo: "メモ"
            case .todo: "TODO"
            case .summary: "要約"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var occurredAt: Date
    public var day: String
    public var todoStatus: LifeLogTodo.Status?

    public init(id: String, kind: Kind, text: String, occurredAt: Date, day: String, todoStatus: LifeLogTodo.Status? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.occurredAt = occurredAt
        self.day = day
        self.todoStatus = todoStatus
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
