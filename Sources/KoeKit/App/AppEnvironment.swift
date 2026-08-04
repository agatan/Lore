import AppKit
import Foundation
import Observation

/// アプリ全体の状態を持つルートオブジェクト。
///
/// UI はここだけを見る。DB・エンジン・権限・キャッシュの更新はすべてここを経由させ、
/// 画面ごとに状態がばらけないようにする。
@MainActor
@Observable
public final class AppEnvironment {
    public enum AnalysisState: Equatable, Sendable {
        case idle
        case running
        case finished(String)
        case failed(String)
    }

    public let settings = AppSettings()
    public let engines = EngineRegistry()
    public let hotkeys = HotkeyMonitor()
    public private(set) var coordinator: DictationCoordinator!

    public private(set) var database: KoeDatabase?
    public private(set) var modes: [Mode] = []
    public private(set) var vocabulary: [VocabularyEntry] = []
    public private(set) var pendingSuggestions: [VocabularySuggestion] = []
    public private(set) var history: [SessionRecord] = []
    public private(set) var historyCount = 0
    public private(set) var latency: LatencyStats?

    public private(set) var bootError: String?
    public private(set) var isAccessibilityGranted = false
    public private(set) var isMicrophoneGranted = false
    public private(set) var hotkeyError: String?
    public private(set) var analysisState: AnalysisState = .idle
    public private(set) var lastAnalysisAt: Date?

    /// メインウィンドウで開いているセクション。メニューからの遷移でも使う。
    public var mainSection: MainSection = .history

    /// モデル取得の進捗(0...1)。nil = 実行中でない。
    public private(set) var modelDownloadProgress: Double?
    public private(set) var modelDownloadError: String?
    public private(set) var modelDiskUsage: Int64 = 0
    /// いまダウンロード中の選択肢。カードに進捗を出すために持つ。
    public private(set) var downloadingChoiceID: ModelChoice.ID?
    /// エンジン・モデル別の実測レイテンシ。
    public private(set) var measuredLatencies = MeasuredLatencies()

    private var permissionWatcher: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    static let analysisIntervalHours = 20.0
    static let lastAnalysisRunKey = "vocab_analysis_last_run"

    public init() {
        coordinator = DictationCoordinator(
            dependencies: .init(
                settings: settings,
                engines: engines,
                historyStore: { [weak self] in self?.database?.history },
                modes: { [weak self] in self?.modes ?? BuiltinModes.all },
                vocabulary: { [weak self] in self?.vocabulary ?? [] },
                onRecordChanged: { [weak self] record in self?.mergeIntoHistory(record) }
            )
        )
        wireHotkeys()
    }

    // MARK: 起動

    public func boot() async {
        refreshPermissions()

        do {
            let database = try await KoeDatabase.openDefault()
            self.database = database
            try await database.modes.seedBuiltinsIfNeeded()
            await reloadModes()
            await reloadVocabulary()
            await reloadHistory()
            await purgeExpiredHistory()
            lastAnalysisAt = try? await database.meta.date(forKey: Self.lastAnalysisRunKey)
        } catch {
            bootError = error.localizedDescription
            KoeLog.persistence.error("DB の初期化に失敗: \(error.localizedDescription, privacy: .public)")
        }

        startHotkeyMonitor()
        startPermissionWatcher()

        await applyEngineChange()
        scheduleBackgroundAnalysis()
    }

    // MARK: ホットキー

    private func wireHotkeys() {
        hotkeys.update(binding: settings.hotkey)
        hotkeys.onEvent = { [weak self] event in
            self?.coordinator.handle(hotkey: event)
        }
        hotkeys.onEscape = { [weak self] in
            guard let self, coordinator.isBusy else { return false }
            coordinator.cancel()
            return true
        }
    }

    public func startHotkeyMonitor() {
        guard Permissions.isAccessibilityGranted else {
            hotkeyError = HotkeyMonitor.Failure.notTrusted.errorDescription
            return
        }
        do {
            hotkeys.update(binding: settings.hotkey)
            try hotkeys.start()
            hotkeyError = nil
        } catch {
            hotkeyError = error.localizedDescription
            KoeLog.hotkey.error("ホットキー監視を開始できません: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func updateHotkey(_ binding: HotkeyBinding) {
        settings.hotkey = binding
        hotkeys.update(binding: binding)
        if !hotkeys.isRunning { startHotkeyMonitor() }
    }

    // MARK: 権限

    public func refreshPermissions() {
        isAccessibilityGranted = Permissions.isAccessibilityGranted
        isMicrophoneGranted = Permissions.isMicrophoneGranted
        // 画面を開いたタイミングは「権限を付与した直後」の可能性が高いので、監視を焚き直す。
        if !isAccessibilityGranted || !isMicrophoneGranted {
            startPermissionWatcher()
        }
    }

    public func requestMicrophone() async {
        _ = await Permissions.requestMicrophone()
        refreshPermissions()
    }

    public func requestAccessibility() {
        Permissions.requestAccessibility()
    }

    /// 権限は「システム設定で後から付与」されるため、未付与のときだけ様子を見る。
    ///
    /// TCC の問い合わせは IPC なので回し続けない。付与を待つのは数分で十分で、
    /// それ以降は画面を開いた契機(`refreshPermissions`)で再開する。
    static let permissionWatchAttempts = 60
    static let permissionWatchInterval: Duration = .seconds(3)

    private func startPermissionWatcher() {
        guard !isAccessibilityGranted || !isMicrophoneGranted else { return }
        guard permissionWatcher == nil else { return }
        permissionWatcher = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.permissionWatcher = nil } }
            for _ in 0..<Self.permissionWatchAttempts {
                try? await Task.sleep(for: Self.permissionWatchInterval)
                guard let self, !Task.isCancelled else { return }
                let hadAccessibility = isAccessibilityGranted
                isAccessibilityGranted = Permissions.isAccessibilityGranted
                isMicrophoneGranted = Permissions.isMicrophoneGranted
                if !hadAccessibility, isAccessibilityGranted {
                    startHotkeyMonitor()
                }
                if isAccessibilityGranted, isMicrophoneGranted { return }
            }
        }
    }

    // MARK: モード

    public func reloadModes() async {
        guard let database else { modes = BuiltinModes.all; return }
        do {
            modes = try await database.modes.all()
            coordinator.refreshPreview()
        } catch {
            KoeLog.persistence.error("モードの読み込みに失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func save(mode: Mode) async {
        guard let database else { return }
        try? await database.modes.save(mode)
        await reloadModes()
    }

    public func deleteMode(id: Mode.ID) async {
        guard let database else { return }
        try? await database.modes.delete(id: id)
        if coordinator.pinnedModeID == id { coordinator.pinnedModeID = nil }
        await reloadModes()
    }

    public func duplicateMode(_ mode: Mode) async -> Mode? {
        var copy = mode
        copy.id = UUID().uuidString
        copy.name = mode.name + " のコピー"
        copy.isBuiltin = false
        copy.sortOrder = (modes.map(\.sortOrder).max() ?? 0) + 10
        await save(mode: copy)
        return copy
    }

    public func resetMode(id: Mode.ID) async {
        guard let database else { return }
        _ = try? await database.modes.resetToBuiltin(id: id)
        await reloadModes()
    }

    // MARK: 語彙

    public func reloadVocabulary() async {
        guard let database else { return }
        do {
            vocabulary = try await database.vocabulary.all()
            pendingSuggestions = try await database.vocabulary.suggestions(status: .pending)
        } catch {
            KoeLog.persistence.error("語彙の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func save(entry: VocabularyEntry) async {
        guard let database else { return }
        try? await database.vocabulary.save(entry)
        await reloadVocabulary()
    }

    public func deleteVocabulary(id: String) async {
        guard let database else { return }
        try? await database.vocabulary.delete(id: id)
        await reloadVocabulary()
    }

    public func acceptSuggestion(id: String) async {
        guard let database else { return }
        _ = try? await database.vocabulary.accept(suggestionID: id)
        await reloadVocabulary()
    }

    public func rejectSuggestion(id: String) async {
        guard let database else { return }
        try? await database.vocabulary.reject(suggestionID: id)
        await reloadVocabulary()
    }

    // MARK: 履歴

    public func reloadHistory(query: String = "") async {
        guard let database else { return }
        do {
            history = try await database.history.search(query: query, limit: 300)
            historyCount = try await database.history.count()
            latency = try await database.history.latencyStats(limit: 100)
            measuredLatencies = try await database.history.measuredLatencies(limit: 300)
        } catch {
            KoeLog.persistence.error("履歴の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func deleteHistory(id: String) async {
        guard let database else { return }
        try? await database.history.delete(id: id)
        await reloadHistory()
    }

    public func deleteAllHistory() async {
        guard let database else { return }
        try? await database.history.deleteAll()
        await reloadHistory()
    }

    public func purgeExpiredHistory() async {
        guard let database, settings.historyRetentionDays > 0 else { return }
        let removed = (try? await database.history.purge(retentionDays: settings.historyRetentionDays)) ?? 0
        if removed > 0 {
            KoeLog.persistence.info("保持期間超過の履歴を \(removed, privacy: .public) 件削除しました")
            await reloadHistory()
        }
    }

    /// 進行中セッションの更新を即座に一覧へ反映する(履歴ウィンドウを開いたままでも追従する)。
    private func mergeIntoHistory(_ record: SessionRecord) {
        if let index = history.firstIndex(where: { $0.id == record.id }) {
            history[index] = record
        } else {
            history.insert(record, at: 0)
            historyCount += 1
        }
    }

    // MARK: 語彙自動提案

    public func runAnalysis(force: Bool) async {
        guard let database, let llm = engines.llmEngine(settings.llmEngineID) else { return }
        guard analysisState != .running else { return }
        analysisState = .running
        let job = VocabularySuggestionJob(
            history: database.history,
            vocabulary: database.vocabulary,
            meta: database.meta,
            llm: llm
        )
        do {
            let result = try await job.run(force: force)
            if let reason = result.skippedReason {
                analysisState = .finished(reason)
            } else {
                analysisState = .finished("\(result.inspectedSessions) 件を分析し、\(result.created) 件の候補を追加しました")
            }
            let now = Date()
            try? await database.meta.setDate(now, forKey: Self.lastAnalysisRunKey)
            lastAnalysisAt = now
            await reloadVocabulary()
        } catch {
            analysisState = .failed(error.localizedDescription)
            KoeLog.analysis.error("語彙分析に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// アイドル時にバックグラウンドで回す(FR-6.4)。起動直後は避ける。
    private func scheduleBackgroundAnalysis() {
        analysisTask?.cancel()
        guard settings.vocabularyAnalysisEnabled else { return }
        if let lastAnalysisAt,
           Date().timeIntervalSince(lastAnalysisAt) < Self.analysisIntervalHours * 3_600 {
            return
        }
        analysisTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, !Task.isCancelled, !coordinator.isBusy else { return }
            await runAnalysis(force: false)
        }
    }

    // MARK: モデル

    /// 聞き取りに使うモデルを選ぶ。
    public func selectTranscription(_ choice: ModelChoice) async {
        settings.sttEngineID = choice.engine
        if let modelID = choice.modelID { settings.whisperModelID = modelID }
        await applyEngineChange()
    }

    /// 仕上げに使うモデルを選ぶ。
    public func selectFormatting(_ choice: ModelChoice) async {
        settings.llmEngineID = choice.engine
        if let modelID = choice.modelID { settings.mlxModelID = modelID }
        await applyEngineChange()
    }

    /// 選択肢のモデルを取得する。選んでから取得するので、取得後すぐ使える状態になる。
    public func download(_ choice: ModelChoice) async {
        if TranscriptionCatalog.all.contains(where: { $0.id == choice.id }) {
            await selectTranscription(choice)
        } else {
            await selectFormatting(choice)
        }
        downloadingChoiceID = choice.id
        defer { downloadingChoiceID = nil }

        await download { [engines, settings] progress in
            switch choice.engine {
            case .whisperKit, .speechAnalyzer:
                try await engines.sttEngine(settings.sttEngineID).install(progress: progress)
            default:
                guard let engine = engines.llmEngine(settings.llmEngineID) else { return }
                try await engine.install(progress: progress)
            }
        }
    }

    public func reloadMeasuredLatencies() async {
        guard let database else { return }
        measuredLatencies = (try? await database.history.measuredLatencies(limit: 300)) ?? MeasuredLatencies()
    }

    private func download(_ operation: (@escaping @Sendable (Double) -> Void) async throws -> Void) async {
        guard modelDownloadProgress == nil else { return }
        modelDownloadProgress = 0
        modelDownloadError = nil
        do {
            try await operation { progress in
                Task { @MainActor [weak self] in self?.modelDownloadProgress = progress }
            }
            modelDownloadProgress = nil
            await applyEngineChange()
        } catch {
            modelDownloadProgress = nil
            modelDownloadError = error.localizedDescription
            KoeLog.engine.error("モデル取得に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func applyEngineChange() async {
        engines.updateModelSelection(whisper: settings.whisperModelID, mlx: settings.mlxModelID)
        await engines.refreshAvailability()
        await engines.prewarm(sttID: settings.sttEngineID, hints: currentHints())
        modelDiskUsage = ModelStore.diskUsage()
    }

    public func deleteDownloadedModels() async {
        try? ModelStore.delete(directory: ModelStore.rootDirectory)
        await engines.unloadAll()
        await applyEngineChange()
    }

    func currentHints() -> SttHints {
        let enabled = vocabulary.filter(\.enabled)
        return SttHints(
            contextualStrings: FormattingPolicy.contextualStrings(enabled),
            vocabularyPrompt: FormattingPolicy.vocabularyHint(enabled),
            languagePreference: .auto
        )
    }

    // MARK: 便利

    #if DEBUG
    /// SwiftUI プレビュー・レイアウト確認用に実測値を差し込む。
    public func applyPreviewMeasured(_ latencies: MeasuredLatencies) {
        measuredLatencies = latencies
    }

    /// SwiftUI プレビュー・レイアウト確認用に履歴を差し込む。
    public func applyPreviewHistory(_ records: [SessionRecord]) {
        history = records
        historyCount = records.count
    }
    #endif

    public var lastResultText: String? {
        coordinator.lastRecord?.resultText ?? history.first(where: { $0.status.isTerminal })?.resultText
    }

    public func copyLastResult() {
        guard let text = lastResultText else { return }
        TextInserter.copyToClipboard(text)
    }
}
