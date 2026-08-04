import Foundation
import GRDB

struct SessionRow: Sendable {
    let id: String
    let startedAt: String
    let endedAt: String?
    let status: String
    let appBundleID: String?
    let appName: String?
    let modeID: String?
    let modeSnapshot: String
    let sttEngine: String
    let sttModel: String?
    let llmEngine: String?
    let llmModel: String?
    let language: String?
    let rawTranscript: String
    let formattedText: String?
    let error: String?
    let audioDurationMs: Int?
    let sttLatencyMs: Int?
    let llmLatencyMs: Int?
    let insertLatencyMs: Int?

    init(record: SessionRecord) throws {
        id = record.id
        startedAt = PersistenceCoding.encode(date: record.startedAt)
        endedAt = record.endedAt.map(PersistenceCoding.encode(date:))
        status = record.status.rawValue
        appBundleID = record.appBundleID
        appName = record.appName
        modeID = record.modeID
        modeSnapshot = try PersistenceCoding.encode(record.modeSnapshot)
        sttEngine = record.sttEngine.rawValue
        sttModel = record.sttModel
        llmEngine = record.llmEngine?.rawValue
        llmModel = record.llmModel
        language = record.language?.rawValue
        rawTranscript = record.rawTranscript
        formattedText = record.formattedText
        error = record.error
        audioDurationMs = record.audioDurationMs
        sttLatencyMs = record.sttLatencyMs
        llmLatencyMs = record.llmLatencyMs
        insertLatencyMs = record.insertLatencyMs
    }

    init(row: Row) {
        id = row["id"]
        startedAt = row["started_at"]
        endedAt = row["ended_at"]
        status = row["status"]
        appBundleID = row["app_bundle_id"]
        appName = row["app_name"]
        modeID = row["mode_id"]
        modeSnapshot = row["mode_snapshot"]
        sttEngine = row["stt_engine"]
        sttModel = row["stt_model"]
        llmEngine = row["llm_engine"]
        llmModel = row["llm_model"]
        language = row["language"]
        rawTranscript = row["raw_transcript"]
        formattedText = row["formatted_text"]
        error = row["error"]
        audioDurationMs = row["audio_duration_ms"]
        sttLatencyMs = row["stt_latency_ms"]
        llmLatencyMs = row["llm_latency_ms"]
        insertLatencyMs = row["insert_latency_ms"]
    }

    func record() throws -> SessionRecord {
        guard let status = SessionStatus(rawValue: status) else {
            throw PersistenceError.invalidStoredValue(column: "status", value: self.status)
        }
        let languageValue: RecognizedLanguage?
        if let language {
            guard let decoded = RecognizedLanguage(rawValue: language) else {
                throw PersistenceError.invalidStoredValue(column: "language", value: language)
            }
            languageValue = decoded
        } else {
            languageValue = nil
        }
        return SessionRecord(
            id: id,
            startedAt: try PersistenceCoding.decodeDate(startedAt),
            endedAt: try endedAt.map(PersistenceCoding.decodeDate),
            status: status,
            appBundleID: appBundleID,
            appName: appName,
            modeID: modeID,
            modeSnapshot: try PersistenceCoding.decode(ModeSnapshot.self, from: modeSnapshot),
            sttEngine: EngineIdentifier(sttEngine),
            sttModel: sttModel,
            llmEngine: llmEngine.map { EngineIdentifier($0) },
            llmModel: llmModel,
            language: languageValue,
            rawTranscript: rawTranscript,
            formattedText: formattedText,
            error: error,
            audioDurationMs: audioDurationMs,
            sttLatencyMs: sttLatencyMs,
            llmLatencyMs: llmLatencyMs,
            insertLatencyMs: insertLatencyMs
        )
    }

    var arguments: StatementArguments {
        [
            id, startedAt, endedAt, status, appBundleID, appName, modeID, modeSnapshot,
            sttEngine, sttModel, llmEngine, llmModel, language, rawTranscript, formattedText,
            error, audioDurationMs, sttLatencyMs, llmLatencyMs, insertLatencyMs,
        ]
    }
}
