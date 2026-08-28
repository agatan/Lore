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
    /// 全モードの前に置かれる共通ルール。編集できる(C-53)。
    public private(set) var sharedRules = BuiltinSharedRules.text
    public private(set) var vocabulary: [VocabularyEntry] = []
    public private(set) var pendingSuggestions: [VocabularySuggestion] = []
    public private(set) var history: [SessionRecord] = []
    public private(set) var historyCount = 0
    public private(set) var latency: LatencyStats?

    public private(set) var bootError: String?
    public private(set) var isAccessibilityGranted = false
    public private(set) var isMicrophoneGranted = false
    /// ログイン項目の状態。問い合わせが同期 XPC なので、UI は必ずこのキャッシュを読む。
    public private(set) var loginItemState: LoginItem.State = .unknown
    public private(set) var hotkeyError: String?
    public private(set) var analysisState: AnalysisState = .idle
    public private(set) var lastAnalysisAt: Date?

    /// メインウィンドウで開いているセクション。メニューからの遷移でも使う。
    public var mainSection: MainSection = .history

    /// 音声モデル取得の進捗(0...1)。nil = 実行中でない。
    public private(set) var speechAssetProgress: Double?
    public private(set) var speechAssetError: String?
    /// Groq に API キーが登録済みか。キーそのものは UI にも状態にも持たない(NFR-2)。
    public private(set) var hasGroqApiKey = false
    /// 設定画面のモデル選択に出す候補。Groq に問い合わせたときだけ埋まる。
    public private(set) var groqModels: [String] = []
    public private(set) var groqStatus: String?
    public private(set) var isCheckingGroq = false
    /// エンジン別の実測レイテンシ。
    public private(set) var measuredLatencies = MeasuredLatencies()

    /// このプロセスが生きている長さ。起動し直すべきかの判断に使う。
    private let launchedAt = ContinuousClock.now
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
                sharedRules: { [weak self] in self?.sharedRules ?? BuiltinSharedRules.text },
                vocabulary: { [weak self] in self?.vocabulary ?? [] },
                onRecordChanged: { [weak self] record in self?.mergeIntoHistory(record) },
                onNeedsAppRestart: { [weak self] in self?.relaunchForLostSpeechInventory() }
            )
        )
        wireHotkeys()
    }

    /// 音声モデルの在庫 API が死んだので、プロセスを作り直す(C-15d)。
    ///
    /// 起動直後に起きているなら作り直しても同じ結果になるだけなので、その場合は
    /// 文言だけ出して手を出さない。ここが再起動ループを止める歯止めになる。
    private func relaunchForLostSpeechInventory() {
        guard ContinuousClock.now - launchedAt > AppRelauncher.minimumUptime else {
            KoeLog.engine.error("起動直後に音声モデルを使えないため、起動し直しは見送ります")
            return
        }
        Task {
            // 理由を読める長さだけ HUD を残してから消える。
            try? await Task.sleep(for: DictationCoordinator.hudNoticeLingerDuration)
            AppRelauncher.relaunch()
        }
    }

    // MARK: 起動

    public func boot() async {
        refreshPermissions()

        do {
            let database = try await KoeDatabase.openDefault()
            self.database = database
            try await database.modes.seedBuiltinsIfNeeded()
            try await database.sharedRules.seedOrMigrate()
            await reloadModes()
            await reloadSharedRules()
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

        // 起動中に済ませておく。設定を開いた瞬間に問い合わせると、その待ちが表示の遅れになる。
        Task { await refreshLoginItem() }
        coordinator.prewarmSounds()

        await applyEngineChange()
        scheduleBackgroundAnalysis()
    }

    // MARK: ホットキー

    private func wireHotkeys() {
        hotkeys.update(binding: settings.hotkey)
        hotkeys.onEvent = { [weak self] event in
            self?.coordinator.handle(hotkey: event)
        }
        // 消費するかどうかだけを同期で答え、中止処理は次のターンへ回す
        // (イベントタップのコールバックを遅くしない、C-57)。
        hotkeys.shouldSwallowEscape = { [weak self] in
            guard let self, coordinator.isBusy else { return false }
            DispatchQueue.main.async { [weak self] in self?.coordinator.cancel() }
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

    /// ホットキーを記録している間はグローバル監視を止める(録音が始まらないように)。
    public func setHotkeyCaptureMode(_ capturing: Bool) {
        hotkeys.setSuspended(capturing)
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

    // MARK: ログイン項目

    public func refreshLoginItem() async {
        loginItemState = await LoginItem.currentState()
    }

    public func setLoginItem(enabled: Bool) async {
        do {
            loginItemState = try await LoginItem.setEnabled(enabled)
        } catch {
            // 反映できなかったので、実際の状態を読み直して UI を現実に合わせる。
            KoeLog.ui.error("ログイン項目の変更に失敗: \(error.localizedDescription, privacy: .public)")
            await refreshLoginItem()
        }
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

    // MARK: 共通ルール

    public func reloadSharedRules() async {
        guard let database else { return }
        do {
            sharedRules = try await database.sharedRules.current()
        } catch {
            KoeLog.persistence.error("共通ルールの読み込みに失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func saveSharedRules(_ text: String) async {
        guard let database else { return }
        try? await database.sharedRules.save(text)
        await reloadSharedRules()
    }

    public func resetSharedRules() async {
        guard let database else { return }
        _ = try? await database.sharedRules.reset()
        await reloadSharedRules()
    }

    /// 同梱内容から変更されているか。
    public var isSharedRulesEdited: Bool { sharedRules != BuiltinSharedRules.text }

    // MARK: モード

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
        guard let database else { return }
        let llm = engines.analysisLlm
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
            analysisState = .finished(Self.message(for: result))
            let now = Date()
            try? await database.meta.setDate(now, forKey: Self.lastAnalysisRunKey)
            lastAnalysisAt = now
            await reloadVocabulary()
        } catch {
            analysisState = .failed(error.localizedDescription)
            KoeLog.analysis.error("語彙分析に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 分析結果の一行報告。部分的な失敗を「成功」に丸めない。
    static func message(for result: VocabularySuggestionJob.Result) -> String {
        if let reason = result.skippedReason { return reason }
        var message = "\(result.inspectedSessions) 件を分析し、\(result.created) 件の候補を追加しました"
        if result.isPartial {
            message += "(\(result.batches) 回のうち \(result.failedBatches) 回が失敗したため、"
                + "残りは次回もう一度分析します)"
        }
        return message
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

    /// 日本語の音声モデルを取得する。OS の資産だが、取得は明示操作で行う。
    public func installSpeechAssets() async {
        guard speechAssetProgress == nil else { return }
        speechAssetProgress = 0
        speechAssetError = nil
        do {
            try await engines.installSpeechAssets { progress in
                Task { @MainActor [weak self] in self?.speechAssetProgress = progress }
            }
            speechAssetProgress = nil
        } catch {
            speechAssetProgress = nil
            speechAssetError = error.localizedDescription
            KoeLog.engine.error("音声モデルの取得に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func reloadMeasuredLatencies() async {
        guard let database else { return }
        measuredLatencies = (try? await database.history.measuredLatencies(limit: 300)) ?? MeasuredLatencies()
    }

    public func applyEngineChange() async {
        engines.apply(backend: settings.formattingBackend, groqModel: settings.groqModel)
        do {
            hasGroqApiKey = try SecretStore.read(.groqApiKey)?.isEmpty == false
        } catch {
            hasGroqApiKey = false
            groqStatus = error.localizedDescription
            KoeLog.engine.error("API キーの確認に失敗: \(error.localizedDescription, privacy: .public)")
        }
        await engines.refreshAvailability()
        await engines.prewarm(hints: currentHints())
    }

    // MARK: Groq

    /// API キーを Keychain に保存する(空文字なら削除)。値は保持しない。
    public func setGroqApiKey(_ key: String) async {
        groqStatus = nil
        do {
            try SecretStore.write(key, for: .groqApiKey)
        } catch {
            groqStatus = error.localizedDescription
            KoeLog.engine.error("API キーの保存に失敗: \(error.localizedDescription, privacy: .public)")
            return
        }
        groqModels = []
        await applyEngineChange()
    }

    /// キーとモデルが実際に通るかを 1 往復して確かめる。
    ///
    /// 整形は失敗しても生テキストにフォールバックするので、設定ミスは
    /// 「なんとなく仕上がらない」形でしか表に出ない。ここで明示的に確かめられるようにする。
    public func checkGroqConnection() async {
        guard !isCheckingGroq else { return }
        isCheckingGroq = true
        groqStatus = nil
        defer { isCheckingGroq = false }

        do {
            groqModels = try await engines.groq.availableModels()
            let reply = try await engines.groq.complete(
                prompt: FormattingPrompt(system: "入力をそのまま返してください。", user: "疎通確認"),
                timeout: .seconds(20)
            )
            groqStatus = reply.isEmpty
                ? "接続できましたが、応答が空でした"
                : "\(settings.groqModel) に接続できました"
        } catch {
            groqStatus = error.localizedDescription
            KoeLog.engine.error("Groq の疎通確認に失敗: \(error.localizedDescription, privacy: .public)")
        }
        await engines.refreshAvailability()
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
