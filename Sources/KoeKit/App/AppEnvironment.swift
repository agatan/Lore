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
    public private(set) static weak var current: AppEnvironment?

    public enum AnalysisState: Equatable, Sendable {
        case idle
        case running
        case finished(String)
        case failed(String)
    }

    public let settings = AppSettings()
    public let engines = EngineRegistry()
    public let hotkeys = HotkeyMonitor()
    public let lifeLogCaptureHotkeys = HotkeyMonitor()
    public let lifeLogMiniWindowHotkeys = HotkeyMonitor()
    public let lifeLog = LifeLogCoordinator()
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
    public var mainSection: MainSection = .lifeLog
    public var settingsSection: SettingsSection = .common
    public var presentsLifeLogAudioConsent = false
    public private(set) var dataOperationError: String?
    public private(set) var lifeLogAudioBytes: Int64 = 0
    public private(set) var appDataBytes: Int64 = 0
    @ObservationIgnored public var onToggleLifeLogMiniWindow: (() -> Void)?
    @ObservationIgnored public var onShowMainWindow: (() -> Void)?

    /// 音声モデル取得の進捗(0...1)。nil = 実行中でない。
    public private(set) var speechAssetProgress: Double?
    public private(set) var speechAssetError: String?
    /// 選択中のクラウドにAPIキーが登録済みか。キーそのものは状態に持たない(NFR-2)。
    public private(set) var hasLlmApiKey = false
    public private(set) var llmModels: [String] = []
    public private(set) var llmStatus: String?
    public private(set) var isCheckingLlm = false
    public private(set) var lifeLogHasLlmApiKey = false
    public private(set) var lifeLogLlmModels: [String] = []
    public private(set) var lifeLogLlmStatus: String?
    public private(set) var isCheckingLifeLogLlm = false
    /// エンジン別の実測レイテンシ。
    public private(set) var measuredLatencies = MeasuredLatencies()
    /// クラウドAIのAPI応答から記録した日別トークン利用量。
    public private(set) var dailyLlmUsage: [DailyLlmUsage] = []
    public private(set) var dailyDictationDuration: [DailyRecordingDuration] = []
    public private(set) var dailyLifeLogDuration: [DailyRecordingDuration] = []

    /// このプロセスが生きている長さ。起動し直すべきかの判断に使う。
    private let launchedAt = ContinuousClock.now
    private var permissionWatcher: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var powerObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var automationObservers: [any NSObjectProtocol] = []
    static let analysisIntervalHours = 20.0
    static let lastAnalysisRunKey = "vocab_analysis_last_run"

    public init() {
        Self.current = self
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
        engines.setUsageSink { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.recordLlmUsage(event)
            }
        }
        wireHotkeys()
        wirePowerNotifications()
        wireAutomationNotifications()
    }

    private func wireAutomationNotifications() {
        let center = DistributedNotificationCenter.default()
        automationObservers.append(center.addObserver(forName: KoeAutomationNotification.dataChanged, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.lifeLog.reload()
                if let date = self?.lifeLog.selectedDate { await self?.lifeLog.loadActivity(containing: date) }
            }
        })
        automationObservers.append(center.addObserver(forName: KoeAutomationNotification.settingsChanged, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.settings.reload() }
        })
    }

    private func wirePowerNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.coordinator.systemWillSleep()
                self?.lifeLog.systemWillSleep()
            }
        })
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.lifeLog.systemDidWake() }
        })
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
            let database: KoeDatabase
#if DEBUG
            if Self.usesScreenshotDemoData {
                database = try await KoeDatabase.inMemory()
                if !Self.usesEmptyUITestData {
                    try await ScreenshotDemoData.seed(database: database)
                }
            } else {
                database = try await KoeDatabase.openDefault()
            }
#else
            database = try await KoeDatabase.openDefault()
#endif
            self.database = database
            await lifeLog.configure(
                database: database,
                engines: engines,
                vocabulary: { [weak self] in self?.vocabulary ?? [] },
                todoPrompt: { [weak self] in self?.settings.lifeLogTodoPrompt ?? BuiltinLifeLogPrompts.todo },
                summaryPrompt: { [weak self] in self?.settings.lifeLogSummaryPrompt ?? BuiltinLifeLogPrompts.summary },
                summaryIntervalMinutes: { [weak self] in self?.settings.lifeLogSummaryIntervalMinutes ?? 60 },
                participatingEventsOnly: { [weak self] in self?.settings.lifeLogParticipatingEventsOnly ?? true }
            )
            lifeLog.selectInputDevice(uid: settings.lifeLogInputDeviceUID)
            try await database.modes.seedBuiltinsIfNeeded()
            try await database.sharedRules.seedOrMigrate()
            await reloadModes()
            await reloadSharedRules()
            await reloadVocabulary()
            await reloadHistory()
            await reloadUsageStatistics()
            await purgeExpiredHistory()
            await purgeExpiredLifeLogAudio()
            refreshStorageSizes()
            lastAnalysisAt = try? await database.meta.date(forKey: Self.lastAnalysisRunKey)
        } catch {
            bootError = error.localizedDescription
            KoeLog.persistence.error("DB の初期化に失敗: \(error.localizedDescription, privacy: .public)")
        }

        startHotkeyMonitor()
        startPermissionWatcher()

        // 起動中に済ませておく。設定を開いた瞬間に問い合わせると、その待ちが表示の遅れになる。
        Task { await refreshLoginItem() }
        await applyEngineChange(checkCredentials: false)
        coordinator.prewarmSounds()
        // SpeechAnalyzerの準備が終わる前に常時録音のAVAudioEngineを起動すると、
        // macOSの音声基盤内で初期化が競合してtrapする。
        if database != nil, settings.lifeLogCaptureEnabled, !Self.usesScreenshotDemoData {
            setLifeLogCaptureEnabled(true)
        }
        scheduleBackgroundAnalysis()
    }

    public func reloadLlmUsage() async {
        guard let database else { dailyLlmUsage = []; return }
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        do {
            dailyLlmUsage = try await database.llmUsage.daily(since: since)
        } catch {
            dataOperationError = error.localizedDescription
        }
    }

    public func reloadUsageStatistics() async {
        await reloadLlmUsage()
        guard let database else {
            dailyDictationDuration = []
            dailyLifeLogDuration = []
            refreshStorageSizes()
            return
        }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let since = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        do {
            async let dictation = database.history.dailyRecordingDuration(since: since, calendar: calendar)
            async let lifeLog = database.lifeLog.dailyRecordingDuration(since: since, calendar: calendar)
            (dailyDictationDuration, dailyLifeLogDuration) = try await (dictation, lifeLog)
#if DEBUG
            if Self.usesScreenshotDemoData {
                let demo = ScreenshotDemoData.recordingDurations(calendar: calendar)
                dailyDictationDuration = demo.dictation
                dailyLifeLogDuration = demo.lifeLog
            }
#endif
        } catch {
            dataOperationError = error.localizedDescription
        }
        refreshStorageSizes()
    }

    public func llmUsage(for purpose: LlmPurpose) -> [DailyLlmUsage] {
        dailyLlmUsage.filter { $0.purpose == purpose }
    }

    private func recordLlmUsage(_ event: LlmUsageEvent) async {
        guard let database else { return }
        do {
            try await database.llmUsage.record(event)
            await reloadLlmUsage()
        } catch {
            dataOperationError = error.localizedDescription
            KoeLog.persistence.error("LLM利用量を保存できません: \(error.localizedDescription, privacy: .public)")
        }
    }

    static var usesScreenshotDemoData: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--koe-screenshot-demo") || usesEmptyUITestData
#else
        false
#endif
    }

    static var usesEmptyUITestData: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--koe-ui-test-empty")
#else
        false
#endif
    }

    static var forcesOnboardingForScreenshot: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--koe-screenshot-onboarding")
#else
        false
#endif
    }

    static var uiTestSettingsSection: SettingsSection? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--koe-ui-test-settings-dictation") { return .models }
        if arguments.contains("--koe-ui-test-settings-life-log") { return .lifeLogAI }
        if arguments.contains("--koe-ui-test-settings-usage") { return .usage }
        if arguments.contains("--koe-ui-test-settings-modes") { return .modes }
#endif
        return nil
    }

    /// UI、global hotkey、App Intentが共有するライフログ記録の状態遷移。
    public func setLifeLogCaptureEnabled(_ enabled: Bool) {
        if enabled, !settings.lifeLogAudioStorageConfirmed {
            settings.lifeLogCaptureEnabled = false
            presentsLifeLogAudioConsent = true
            mainSection = .lifeLog
            onShowMainWindow?()
            return
        }
        settings.lifeLogCaptureEnabled = enabled
        lifeLog.setCaptureEnabled(enabled)
    }

    public func confirmLifeLogAudioStorageAndStart() {
        settings.lifeLogAudioStorageConfirmed = true
        presentsLifeLogAudioConsent = false
        setLifeLogCaptureEnabled(true)
    }

    public func cancelLifeLogAudioStorageConsent() {
        settings.lifeLogCaptureEnabled = false
        presentsLifeLogAudioConsent = false
    }

    /// 終了前に音声入力またはライフログの確定を待つ必要がある状態。
    public var hasPendingTerminationWork: Bool {
        coordinator.isBusy || lifeLog.hasPendingTerminationWork
    }

    /// すべての終了動線が共有する保存境界。録音意図を下ろしてから処理中の音声を確定する。
    public func prepareForTermination() async {
        hotkeys.stop()
        lifeLogCaptureHotkeys.stop()
        lifeLogMiniWindowHotkeys.stop()
        permissionWatcher?.cancel()
        analysisTask?.cancel()
        if coordinator.isRecording { coordinator.stop() }
        settings.lifeLogCaptureEnabled = false

        async let lifeLogFinished = lifeLog.stopAndWait()
        let clock = ContinuousClock()
        let dictationDeadline = clock.now.advanced(by: .seconds(10))
        while coordinator.isBusy, clock.now < dictationDeadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }
        if await !lifeLogFinished {
            KoeLog.persistence.error("終了期限までにライフログ処理を完了できませんでした。保存済み音声は次回起動時に再処理します")
        }
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
        lifeLogCaptureHotkeys.update(binding: settings.lifeLogCaptureHotkey)
        lifeLogCaptureHotkeys.onEvent = { [weak self] event in
            guard case .released = event, let self else { return }
            let enabled = !lifeLog.isCapturing
            setLifeLogCaptureEnabled(enabled)
        }
        lifeLogMiniWindowHotkeys.update(binding: settings.lifeLogMiniWindowHotkey)
        lifeLogMiniWindowHotkeys.onEvent = { [weak self] event in
            guard case .released = event else { return }
            self?.onToggleLifeLogMiniWindow?()
        }
    }

    public func startHotkeyMonitor() {
        guard Permissions.isAccessibilityGranted else {
            hotkeyError = HotkeyMonitor.Failure.notTrusted.errorDescription
            return
        }
        do {
            hotkeys.update(binding: settings.hotkey)
            lifeLogCaptureHotkeys.update(binding: settings.lifeLogCaptureHotkey)
            lifeLogMiniWindowHotkeys.update(binding: settings.lifeLogMiniWindowHotkey)
            try hotkeys.start()
            try lifeLogCaptureHotkeys.start()
            try lifeLogMiniWindowHotkeys.start()
            hotkeyError = nil
        } catch {
            hotkeyError = error.localizedDescription
            KoeLog.hotkey.error("ホットキー監視を開始できません: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// ホットキーを記録している間はグローバル監視を止める(録音が始まらないように)。
    public func setHotkeyCaptureMode(_ capturing: Bool) {
        hotkeys.setSuspended(capturing)
        lifeLogCaptureHotkeys.setSuspended(capturing)
        lifeLogMiniWindowHotkeys.setSuspended(capturing)
    }

    public func updateHotkey(_ binding: HotkeyBinding) {
        guard binding != settings.lifeLogCaptureHotkey, binding != settings.lifeLogMiniWindowHotkey else {
            hotkeyError = "同じキーを複数の操作には割り当てられません"
            return
        }
        settings.hotkey = binding
        hotkeys.update(binding: binding)
        if !hotkeys.isRunning { startHotkeyMonitor() }
    }

    public func updateLifeLogCaptureHotkey(_ binding: HotkeyBinding) {
        guard binding != settings.hotkey, binding != settings.lifeLogMiniWindowHotkey else {
            hotkeyError = "同じキーを複数の操作には割り当てられません"
            return
        }
        settings.lifeLogCaptureHotkey = binding
        lifeLogCaptureHotkeys.update(binding: binding)
        hotkeyError = nil
        if !lifeLogCaptureHotkeys.isRunning { startHotkeyMonitor() }
    }

    public func updateLifeLogMiniWindowHotkey(_ binding: HotkeyBinding) {
        guard binding != settings.hotkey, binding != settings.lifeLogCaptureHotkey else {
            hotkeyError = "同じキーを複数の操作には割り当てられません"
            return
        }
        settings.lifeLogMiniWindowHotkey = binding
        lifeLogMiniWindowHotkeys.update(binding: binding)
        hotkeyError = nil
        if !lifeLogMiniWindowHotkeys.isRunning { startHotkeyMonitor() }
    }

    public func setLifeLogMiniWindowAlwaysOnTop(_ enabled: Bool) {
        settings.lifeLogMiniWindowAlwaysOnTop = enabled
        applyLifeLogMiniWindowLevel()
    }

    public func applyLifeLogMiniWindowLevel() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == KoeWindow.lifeLogMini }) else { return }
        window.level = settings.lifeLogMiniWindowAlwaysOnTop ? .floating : .normal
        window.collectionBehavior = settings.lifeLogMiniWindowAlwaysOnTop ? [.fullScreenAuxiliary] : []
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
        guard await performDataOperation({ try await database.sharedRules.save(text) }) else { return }
        await reloadSharedRules()
    }

    public func resetSharedRules() async {
        guard let database else { return }
        guard await performDataOperation({ _ = try await database.sharedRules.reset() }) else { return }
        await reloadSharedRules()
    }

    /// 同梱内容から変更されているか。
    public var isSharedRulesEdited: Bool { sharedRules != BuiltinSharedRules.text }

    // MARK: モード

    public func save(mode: Mode) async {
        guard let database else { return }
        guard await performDataOperation({ try await database.modes.save(mode) }) else { return }
        await reloadModes()
    }

    public func deleteMode(id: Mode.ID) async {
        guard let database else { return }
        do {
            try await database.modes.delete(id: id)
            if coordinator.pinnedModeID == id { coordinator.pinnedModeID = nil }
            await reloadModes()
        } catch {
            dataOperationError = error.localizedDescription
        }
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
        do {
            _ = try await database.modes.resetToInitial(id: id)
            await reloadModes()
        } catch {
            dataOperationError = error.localizedDescription
        }
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
        guard await performDataOperation({ try await database.vocabulary.save(entry) }) else { return }
        await reloadVocabulary()
        lifeLog.vocabularyDidChange()
    }

    public func deleteVocabulary(id: String) async {
        guard let database else { return }
        guard await performDataOperation({ try await database.vocabulary.delete(id: id) }) else { return }
        await reloadVocabulary()
        lifeLog.vocabularyDidChange()
    }

    public func acceptSuggestion(id: String) async {
        guard let database else { return }
        guard await performDataOperation({ _ = try await database.vocabulary.accept(suggestionID: id) }) else { return }
        await reloadVocabulary()
        lifeLog.vocabularyDidChange()
    }

    public func rejectSuggestion(id: String) async {
        guard let database else { return }
        guard await performDataOperation({ try await database.vocabulary.reject(suggestionID: id) }) else { return }
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
        guard await performDataOperation({ try await database.history.delete(id: id) }) else { return }
        await reloadHistory()
    }

    public func deleteAllHistory() async {
        guard let database else { return }
        dataOperationError = nil
        do {
            try await database.history.deleteAll()
            await reloadHistory()
        } catch {
            reportDataOperation(error)
        }
    }

    public func purgeExpiredHistory() async {
        guard let database, settings.historyRetentionDays > 0 else { return }
        do {
            let removed = try await database.history.purge(retentionDays: settings.historyRetentionDays)
            if removed > 0 {
                KoeLog.persistence.info("保持期間超過の履歴を \(removed, privacy: .public) 件削除しました")
                await reloadHistory()
            }
        } catch {
            reportDataOperation(error)
        }
    }

    // MARK: 保存データ

    public func purgeExpiredLifeLogAudio() async {
        guard let database, settings.lifeLogAudioRetentionDays > 0 else { return }
        guard let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -settings.lifeLogAudioRetentionDays,
            to: Date()
        ) else { return }
        do {
            for url in try await database.lifeLog.audioFileURLs(endedBefore: cutoff) {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            refreshLifeLogAudioSize()
        } catch {
            reportDataOperation(error)
        }
    }

    public func deleteAllLifeLogData() async {
        guard let database else { return }
        dataOperationError = nil
        settings.lifeLogCaptureEnabled = false
        guard await lifeLog.stopAndWait() else {
            reportDataOperation(DataOperationError.captureDidNotStop)
            return
        }
        do {
            try removeLifeLogAudioDirectory()
            try await database.lifeLog.deleteAll()
            await lifeLog.reload()
            await lifeLog.loadActivity(containing: lifeLog.selectedDate)
            refreshLifeLogAudioSize()
        } catch {
            reportDataOperation(error)
        }
    }

    public func deleteAllApplicationData() async {
        guard let database else { return }
        dataOperationError = nil
        settings.lifeLogCaptureEnabled = false
        guard await lifeLog.stopAndWait() else {
            reportDataOperation(DataOperationError.captureDidNotStop)
            return
        }
        do {
            try removeLifeLogAudioDirectory()
            try SecretStore.deleteAll()
            try database.deleteBackups()
            try await database.deleteAllUserData()
            settings.resetAll()
            engines.apply(
                backend: settings.formattingBackend,
                model: settings.model(for: settings.formattingBackend, purpose: .dictation),
                purpose: .dictation
            )
            engines.apply(
                backend: settings.lifeLogFormattingBackend,
                model: settings.model(for: settings.lifeLogFormattingBackend, purpose: .lifeLog),
                purpose: .lifeLog
            )
            try await database.modes.seedBuiltinsIfNeeded()
            try await database.sharedRules.seedOrMigrate()
            await reloadModes()
            await reloadSharedRules()
            await reloadVocabulary()
            await reloadHistory()
            await lifeLog.reload()
            await lifeLog.loadActivity(containing: lifeLog.selectedDate)
            refreshLifeLogAudioSize()
        } catch {
            reportDataOperation(error)
        }
    }

    public func refreshStorageSizes() {
#if DEBUG
        if Self.usesScreenshotDemoData {
            lifeLogAudioBytes = 184_000_000
            appDataBytes = 197_000_000
            return
        }
#endif
        lifeLogAudioBytes = Self.directorySize(at: Self.lifeLogAudioRoot)
        appDataBytes = Self.directorySize(at: Self.appDataRoot)
    }

    public func refreshLifeLogAudioSize() {
        refreshStorageSizes()
    }

    private static func directorySize(at root: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in files {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            } catch {
                KoeLog.persistence.error("保存容量を確認できません: \(error.localizedDescription, privacy: .public)")
            }
        }
        return total
    }

    private static var appDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe", isDirectory: true)
    }

    private static var lifeLogAudioRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/LifeLog", isDirectory: true)
    }

    private func removeLifeLogAudioDirectory() throws {
        let root = Self.lifeLogAudioRoot
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func reportDataOperation(_ error: Error) {
        dataOperationError = error.localizedDescription
        KoeLog.persistence.error("保存データの操作に失敗: \(error.localizedDescription, privacy: .public)")
    }

    private func performDataOperation(_ operation: () async throws -> Void) async -> Bool {
        dataOperationError = nil
        do {
            try await operation()
            return true
        } catch {
            reportDataOperation(error)
            return false
        }
    }

    private enum DataOperationError: LocalizedError {
        case captureDidNotStop

        var errorDescription: String? {
            "録音の保存処理が終わらなかったため、データを削除しませんでした。もう一度お試しください。"
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
        if record.status == .completed || record.status == .fallback || record.status == .clipboardOnly {
            Task { await lifeLog.reload() }
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

    public func applyEngineChange(
        purpose: LlmPurpose? = nil,
        checkCredentials: Bool = true,
        resetConnectionState: Bool = false
    ) async {
        if purpose == nil || purpose == .dictation {
            await applyEngineChange(for: .dictation, checkCredentials: checkCredentials, resetConnectionState: resetConnectionState)
        }
        if purpose == nil || purpose == .lifeLog {
            await applyEngineChange(for: .lifeLog, checkCredentials: checkCredentials, resetConnectionState: resetConnectionState)
        }
        await engines.refreshSttAvailability()
        for target in LlmPurpose.allCases where purpose == nil || purpose == target {
            if checkCredentials || settings.backend(for: target) == .onDevice {
                await engines.refreshLlmAvailability(for: target)
            }
        }
    }

    private func applyEngineChange(for purpose: LlmPurpose, checkCredentials: Bool, resetConnectionState: Bool) async {
        let backend = settings.backend(for: purpose)
        engines.apply(backend: backend, model: settings.model(for: backend, purpose: purpose), purpose: purpose)
        if resetConnectionState {
            setLlmModels([], for: purpose)
            setLlmStatus(nil, for: purpose)
        }
        if checkCredentials {
            do {
                let hasKey = if let key = secretKey(for: backend, purpose: purpose) {
                    try SecretStore.read(key)?.isEmpty == false
                } else {
                    true
                }
                setHasLlmApiKey(hasKey, for: purpose)
            } catch {
                setHasLlmApiKey(false, for: purpose)
                setLlmStatus(error.localizedDescription, for: purpose)
                KoeLog.engine.error("API キーの確認に失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: 文章処理エンジン

    /// API キーを Keychain に保存する(空文字なら削除)。値は保持しない。
    public func setLlmApiKey(_ key: String, purpose: LlmPurpose = .dictation) async {
        let backend = settings.backend(for: purpose)
        guard let secretKey = secretKey(for: backend, purpose: purpose) else { return }
        setLlmStatus(nil, for: purpose)
        do {
            try SecretStore.write(key, for: secretKey)
        } catch {
            setLlmStatus(error.localizedDescription, for: purpose)
            KoeLog.engine.error("API キーの保存に失敗: \(error.localizedDescription, privacy: .public)")
            return
        }
        setLlmModels([], for: purpose)
        await applyEngineChange(purpose: purpose)
    }

    /// キーとモデルが実際に通るかを 1 往復して確かめる。
    ///
    /// 整形は失敗しても生テキストにフォールバックするので、設定ミスは
    /// 「なんとなく仕上がらない」形でしか表に出ない。ここで明示的に確かめられるようにする。
    public func checkLlmConnection(purpose: LlmPurpose = .dictation) async {
        guard !isCheckingLlm(for: purpose) else { return }
        setIsCheckingLlm(true, for: purpose)
        setLlmStatus(nil, for: purpose)
        defer { setIsCheckingLlm(false, for: purpose) }

        do {
            let backend = settings.backend(for: purpose)
            setLlmModels(try await engines.availableModels(for: backend, purpose: purpose), for: purpose)
            let engine = purpose == .dictation ? engines.llm : engines.lifeLogLlm
            let reply = try await engine.complete(
                prompt: FormattingPrompt(system: "入力をそのまま返してください。", user: "疎通確認"),
                timeout: .seconds(20)
            )
            setLlmStatus(reply.isEmpty
                ? "接続できましたが、応答が空でした"
                : "\(settings.model(for: backend, purpose: purpose)) に接続できました", for: purpose)
        } catch {
            setLlmStatus(error.localizedDescription, for: purpose)
            KoeLog.engine.error("LLM の疎通確認に失敗: \(error.localizedDescription, privacy: .public)")
        }
        await engines.refreshLlmAvailability(for: purpose)
    }

    private func secretKey(for backend: FormattingBackend, purpose: LlmPurpose) -> SecretStore.Key? {
        switch (purpose, backend) {
        case (.dictation, .openAI): .openAIApiKey
        case (.dictation, .anthropic): .anthropicApiKey
        case (.dictation, .gemini): .geminiApiKey
        case (.dictation, .groq): .groqApiKey
        case (.lifeLog, .openAI): .lifeLogOpenAIApiKey
        case (.lifeLog, .anthropic): .lifeLogAnthropicApiKey
        case (.lifeLog, .gemini): .lifeLogGeminiApiKey
        case (.lifeLog, .groq): .lifeLogGroqApiKey
        case (_, .onDevice), (_, .ollama), (_, .lmStudio): nil
        }
    }

    public func hasLlmApiKey(for purpose: LlmPurpose) -> Bool { purpose == .dictation ? hasLlmApiKey : lifeLogHasLlmApiKey }
    public func llmModels(for purpose: LlmPurpose) -> [String] { purpose == .dictation ? llmModels : lifeLogLlmModels }
    public func llmStatus(for purpose: LlmPurpose) -> String? { purpose == .dictation ? llmStatus : lifeLogLlmStatus }
    public func isCheckingLlm(for purpose: LlmPurpose) -> Bool { purpose == .dictation ? isCheckingLlm : isCheckingLifeLogLlm }
    public func llmAvailability(for purpose: LlmPurpose) -> EngineAvailability { purpose == .dictation ? engines.llmAvailability : engines.lifeLogLlmAvailability }

    private func setHasLlmApiKey(_ value: Bool, for purpose: LlmPurpose) {
        if purpose == .dictation { hasLlmApiKey = value } else { lifeLogHasLlmApiKey = value }
    }
    private func setLlmModels(_ value: [String], for purpose: LlmPurpose) {
        if purpose == .dictation { llmModels = value } else { lifeLogLlmModels = value }
    }
    private func setLlmStatus(_ value: String?, for purpose: LlmPurpose) {
        if purpose == .dictation { llmStatus = value } else { lifeLogLlmStatus = value }
    }
    private func setIsCheckingLlm(_ value: Bool, for purpose: LlmPurpose) {
        if purpose == .dictation { isCheckingLlm = value } else { isCheckingLifeLogLlm = value }
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
