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

    /// 旧名Koeの設定は、設定を読む前に新しいdomainへ写す。
    public let settings: AppSettings = {
        if Bundle.main.bundleIdentifier == AppEnvironment.bundleIdentifier {
            LegacyKoeMigration.migrateDefaults(legacyDomain: LegacyKoeMigration.legacyDefaultsDomain(), into: .standard)
        }
        return AppSettings()
    }()
    public let engines = EngineRegistry()
    public let hotkeys = HotkeyMonitor()
    public let lifeLogCaptureHotkeys = HotkeyMonitor()
    public let lifeLogMiniWindowHotkeys = HotkeyMonitor()
    public let voiceMemoHotkeys = HotkeyMonitor()
    public let lifeLog = LifeLogCoordinator()
    public let sync = SyncCoordinator()
    public private(set) var coordinator: DictationCoordinator!

    public private(set) var database: LoreDatabase?
    public private(set) var modes: [Mode] = []
    /// 全モードの前に置かれる共通ルール。編集できる(C-53)。
    public private(set) var sharedRules = BuiltinSharedRules.text
    public private(set) var vocabulary: [VocabularyEntry] = []
    public private(set) var history: [SessionRecord] = []
    public private(set) var historyCount = 0
    public private(set) var latency: LatencyStats?

    public private(set) var bootError: String?
    /// 旧名Koeのデータを移す途中で起きたこと。記録は使えるが、利用者の確認が要る。
    public private(set) var dataMigrationIssue: String?
    public private(set) var isAccessibilityGranted = false
    public private(set) var isInputMonitoringGranted = false
    public private(set) var isMicrophoneGranted = false
    public private(set) var isCalendarGranted = false
    /// ログイン項目の状態。問い合わせが同期 XPC なので、UI は必ずこのキャッシュを読む。
    public private(set) var loginItemState: LoginItem.State = .unknown
    public private(set) var hotkeyError: String?
    public private(set) var isPreparingVoiceMemo = false

    /// メインウィンドウで開いているセクション。メニューからの遷移でも使う。
    public var mainSection: MainSection = .lifeLog
    public var settingsSection: SettingsSection = .common
    public var presentsLifeLogAudioConsent = false
    public private(set) var dataOperationError: String?
    public private(set) var lifeLogAudioBytes: Int64 = 0
    public private(set) var appDataBytes: Int64 = 0
    @ObservationIgnored public var onToggleLifeLogMiniWindow: (() -> Void)?
    @ObservationIgnored public var onShowMainWindow: (() -> Void)?
    @ObservationIgnored public var onShowSettings: ((SettingsSection) -> Void)?

    /// 音声モデル取得の進捗(0...1)。nil = 実行中でない。
    public private(set) var speechAssetProgress: Double?
    public private(set) var speechAssetError: String?
    public private(set) var whisperProgress: Double?
    public private(set) var whisperError: String?
    /// 選択中のクラウドにAPIキーが登録済みか。キーそのものは状態に持たない(NFR-2)。
    public private(set) var hasLlmApiKey = false
    public private(set) var llmModels: [String] = []
    public private(set) var llmStatus: String?
    public private(set) var isCheckingLlm = false
    /// エンジン別の実測レイテンシ。
    public private(set) var measuredLatencies = MeasuredLatencies()

    /// このプロセスが生きている長さ。起動し直すべきかの判断に使う。
    private let launchedAt = ContinuousClock.now
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    @ObservationIgnored private var whisperInstallTask: Task<Void, Never>?
    private var permissionWatcher: Task<Void, Never>?
    @ObservationIgnored private var powerObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var clockObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    /// 自動記録の判断状態。表示（自動記録中か）にも使うため観測対象にする。
    public private(set) var lifeLogScheduleState = LifeLogScheduleController()

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
        wireHotkeys()
        wirePowerNotifications()
        followApplicationLanguage()
    }

    /// coordinatorやengineが組み立てる文言も、Viewと同じ表示言語で作らせる。
    private func followApplicationLanguage() {
        LoreLocalization.language = withObservationTracking {
            settings.applicationLanguage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followApplicationLanguage() }
        }
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
            Task { @MainActor [weak self] in
                self?.lifeLog.systemDidWake()
                self?.applyLifeLogSchedule()
            }
        })
        // 時計やtime zoneが変わると、次の切替時刻の計算が古くなる。
        let local = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            clockObservers.append(local.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyLifeLogSchedule() }
            })
        }
    }

    /// 音声モデルの在庫 API が死んだので、プロセスを作り直す(C-15d)。
    ///
    /// 起動直後に起きているなら作り直しても同じ結果になるだけなので、その場合は
    /// 文言だけ出して手を出さない。ここが再起動ループを止める歯止めになる。
    private func relaunchForLostSpeechInventory() {
        guard ContinuousClock.now - launchedAt > AppRelauncher.minimumUptime else {
            LoreLog.engine.error("起動直後に音声モデルを使えないため、起動し直しは見送ります")
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
        if let bootTask {
            await bootTask.value
            return
        }
        let task = Task { @MainActor in
            await self.performBoot()
        }
        bootTask = task
        await task.value
    }

    private func performBoot() async {
        refreshPermissions()

        if Bundle.main.bundleIdentifier == Self.bundleIdentifier, !Self.usesScreenshotDemoData {
            migrateLegacySecrets()
        }

        do {
            let database: LoreDatabase
#if DEBUG
            if Self.usesScreenshotDemoData {
                database = try await LoreDatabase.inMemory()
                if !Self.usesEmptyUITestData {
                    try await ScreenshotDemoData.seed(database: database)
                }
            } else {
                database = try await openDefaultDatabase()
            }
#else
            database = try await openDefaultDatabase()
#endif
            self.database = database
            await lifeLog.configure(
                database: database,
                engines: engines,
                vocabulary: { [weak self] in self?.vocabulary ?? [] },
                transcriptionLanguage: { [weak self] in
                    guard let self else { return .auto }
                    return settings.lifeLogTranscriptionLanguage.preference(
                        applicationLanguage: settings.applicationLanguage
                    )
                },
                participatingEventsOnly: { [weak self] in self?.settings.lifeLogParticipatingEventsOnly ?? true },
                audioProcessingCompleted: { [weak self] in await self?.purgeExpiredLifeLogAudio() }
            )
            lifeLog.selectInputDevice(uid: settings.lifeLogInputDeviceUID)
            try await database.modes.seedBuiltinsIfNeeded()
            try await database.sharedRules.seedOrMigrate()
            await reloadModes()
            await reloadSharedRules()
            await reloadVocabulary()
            await reloadHistory()
            await purgeExpiredHistory()
            await purgeExpiredLifeLogAudio()
            refreshStorageSizes()
            if !Self.isUITestBundle {
                await sync.configure(database: database) { [weak self] in await self?.reloadAfterSync() }
            }
        } catch {
            bootError = error.localizedDescription
            LoreLog.persistence.error("DB の初期化に失敗: \(error.localizedDescription, privacy: .public)")
        }

        if !Self.isUITestBundle {
            startHotkeyMonitor()
            startPermissionWatcher()
        }

        // 起動中に済ませておく。設定を開いた瞬間に問い合わせると、その待ちが表示の遅れになる。
        Task { await refreshLoginItem() }
        await applyEngineChange(checkCredentials: false)
        coordinator.prewarmSounds()
        // 記録開始は必ずこのプロセスでの明示操作から行う。
        // crash等で残った前回のruntime stateを起動意図として復元しない。
        settings.lifeLogCaptureEnabled = false
        // 前回の記録意図ではなく、利用者が決めた時間帯の中にいる場合だけ自動で開始する。
        if database != nil, !Self.isUITestBundle { applyLifeLogSchedule() }
    }

    static var usesScreenshotDemoData: Bool {
#if DEBUG
        isUITestBundle || ProcessInfo.processInfo.arguments.contains("--lore-screenshot-demo") || usesEmptyUITestData
#else
        false
#endif
    }

    static let bundleIdentifier = "dev.agatan.Lore"

    /// 旧Koeのfolderを移してからDBを開く。両方あった場合は新しい方を使い、旧folderの場所を知らせる。
    private func openDefaultDatabase() async throws -> LoreDatabase {
        let (database, outcome) = try await LoreDatabase.openDefault()
        if case .leftLegacyInPlace(let legacy) = outcome {
            appendDataMigrationIssue(String(lore: "以前のKoeのデータが\(legacy.path)に残っています。Loreのデータがすでにあったため、混ぜずに残しました。"))
        }
        return database
    }

    private func migrateLegacySecrets() {
        do {
            let migrated = try SecretStore.migrateLegacyKoeService()
            if !migrated.isEmpty {
                LoreLog.persistence.info("旧KoeのKeychain項目を移しました: \(migrated.count, privacy: .public)件")
            }
        } catch {
            LoreLog.persistence.error("旧KoeのKeychain項目を移せません: \(error.localizedDescription, privacy: .public)")
            appendDataMigrationIssue(error.localizedDescription)
        }
    }

    private func appendDataMigrationIssue(_ message: String) {
        dataMigrationIssue = [dataMigrationIssue, message].compactMap { $0 }.joined(separator: "\n")
    }

    static var isUITestBundle: Bool {
        Bundle.main.bundleIdentifier == "\(bundleIdentifier).UIE2E"
    }

    static var usesEmptyUITestData: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--lore-ui-test-empty")
#else
        false
#endif
    }

    static var forcesOnboardingForScreenshot: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--lore-screenshot-onboarding")
#else
        false
#endif
    }

    static var uiTestSettingsSection: SettingsSection? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--lore-ui-test-settings-dictation") { return .models }
        if arguments.contains("--lore-ui-test-settings-life-log") { return .lifeLog }
        if arguments.contains("--lore-ui-test-settings-modes") { return .modes }
        if arguments.contains("--lore-ui-test-settings-calendar") { return .calendar }
        if arguments.contains("--lore-ui-test-settings-privacy") { return .privacy }
#endif
        return nil
    }

    /// UI、global hotkey、App Intentが共有するライフログ記録の状態遷移。
    /// 手動の開始・停止は自動記録の所有から外し、時間帯の途中の停止は次の時間帯まで再開しない。
    public func setLifeLogCaptureEnabled(_ enabled: Bool) {
        lifeLogScheduleState.userChangedCapture(enabled: enabled, schedule: settings.lifeLogSchedule, now: Date())
        applyLifeLogCapture(enabled)
    }

    private func applyLifeLogCapture(_ enabled: Bool) {
        if enabled, !settings.lifeLogAudioStorageConfirmed {
            settings.lifeLogCaptureEnabled = false
            presentsLifeLogAudioConsent = true
            mainSection = .lifeLog
            onShowMainWindow?()
            return
        }
        settings.lifeLogCaptureEnabled = enabled
        lifeLog.setCaptureEnabled(enabled)
        guard !enabled else { return }
        Task { [weak self] in
            guard let self, await lifeLog.stopAndWait(), !lifeLog.hasCaptureIntent else { return }
            await engines.unloadLifeLogStt()
        }
    }

    public func confirmLifeLogAudioStorageAndStart() {
        settings.lifeLogAudioStorageConfirmed = true
        presentsLifeLogAudioConsent = false
        setLifeLogCaptureEnabled(true)
    }

    // MARK: 自動記録

    public enum LifeLogScheduleCaption: Equatable, Sendable {
        case recordingUntil(String)
        case nextStart(String)
    }

    public func updateLifeLogSchedule(_ schedule: LifeLogSchedule) {
        settings.lifeLogSchedule = schedule
        applyLifeLogSchedule()
    }

    /// 現在時刻で自動記録の開始・停止を判断し、次の切替時刻に一度だけ起きる。
    func applyLifeLogSchedule(now: Date = Date()) {
        scheduleTask?.cancel()
        scheduleTask = nil
        let schedule = settings.lifeLogSchedule
        switch lifeLogScheduleState.evaluate(schedule: schedule, now: now, hasCaptureIntent: lifeLog.hasCaptureIntent) {
        case .start:
            if settings.lifeLogAudioStorageConfirmed {
                applyLifeLogCapture(true)
            } else {
                // 同意画面を勝手に開かない。不在時に起きた時間帯の開始でwindowを奪わないため。
                lifeLogScheduleState.startFailed(schedule: schedule, now: now)
                lifeLog.showNotice(String(lore: "自動記録を始められませんでした。録音の保存に同意するため、一度手動でライフログを開始してください"))
            }
        case .stop:
            applyLifeLogCapture(false)
        case .none:
            break
        }
        guard let next = schedule.nextTransition(after: now) else { return }
        scheduleTask = Task { [weak self] in
            // 境界ちょうどの時刻は時間帯の外/内の判定が揺れないよう、わずかに過ぎてから評価する。
            let delay = max(0, next.timeIntervalSinceNow) + 0.5
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.applyLifeLogSchedule()
        }
    }

    /// 自動記録の状態表示。自動記録中は終了時刻、待機中は次の開始時刻を返す。
    public var lifeLogScheduleCaption: LifeLogScheduleCaption? {
        let schedule = settings.lifeLogSchedule
        guard schedule.isEnabled else { return nil }
        let now = Date()
        if lifeLog.hasCaptureIntent {
            guard lifeLogScheduleState.ownsCapture,
                  let window = schedule.window(containing: now) else { return nil }
            return .recordingUntil(Self.scheduleTimeText(window.end, now: now))
        }
        guard let next = schedule.nextWindow(after: now) else { return nil }
        return .nextStart(Self.scheduleTimeText(next.start, now: now))
    }

    /// 今日なら時刻だけ、別の日なら曜日を添える。
    static func scheduleTimeText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.loreFormatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return date.loreFormatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated)) + " " + time
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
        voiceMemoHotkeys.stop()
        permissionWatcher?.cancel()
        scheduleTask?.cancel()
        settings.lifeLogCaptureEnabled = false

        async let lifeLogFinished = lifeLog.stopForTermination()
        async let dictationFinished: Void = coordinator.interruptForTermination()
        await dictationFinished
        if await !lifeLogFinished {
            LoreLog.persistence.error("終了期限までにライフログ処理を完了できませんでした。保存済み音声は次回起動時に再処理します")
        }
    }

    // MARK: ホットキー

    private func wireHotkeys() {
        hotkeys.update(binding: settings.hotkey)
        hotkeys.onEvent = { [weak self] event in
            self?.coordinator.handle(hotkey: event)
        }
        // 消費するかどうかだけを同期で答え、中止処理は次のターンへ回す
        // (入力eventのコールバックを遅くしない、C-57)。
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
        voiceMemoHotkeys.update(binding: settings.voiceMemoHotkey)
        voiceMemoHotkeys.onEvent = { [weak self] event in
            guard case .pressed = event else { return }
            self?.toggleVoiceMemo()
        }
    }

    public func startHotkeyMonitor() {
        let registrations: [(String, HotkeyMonitor, HotkeyBinding)] = [
            (String(lore: "音声入力"), hotkeys, settings.hotkey),
            (String(lore: "ライフログ"), lifeLogCaptureHotkeys, settings.lifeLogCaptureHotkey),
            (String(lore: "ミニウィンドウ"), lifeLogMiniWindowHotkeys, settings.lifeLogMiniWindowHotkey),
            (String(lore: "ボイスメモ"), voiceMemoHotkeys, settings.voiceMemoHotkey),
        ]
        if requiresInputMonitoring, !Permissions.isInputMonitoringGranted {
            _ = Permissions.requestInputMonitoring()
        }
        isInputMonitoringGranted = Permissions.isInputMonitoringGranted
        var failures: [String] = []
        var started = 0
        for (name, monitor, binding) in registrations {
            monitor.stop()
            monitor.update(binding: binding)
            do {
                try monitor.start()
                started += 1
            } catch {
                let message = "\(name): \(error.localizedDescription)"
                failures.append(message)
                LoreLog.hotkey.error("ホットキー監視を開始できません: \(message, privacy: .public)")
            }
        }
        hotkeyError = failures.isEmpty ? nil : failures.joined(separator: " / ")
        LoreLog.hotkey.info("\(started, privacy: .public)/4本のグローバルホットキー監視を開始しました")
    }

    /// ホットキーを記録している間はグローバル監視を止める(録音が始まらないように)。
    public func setHotkeyCaptureMode(_ capturing: Bool) {
        if capturing {
            hotkeys.stop()
            lifeLogCaptureHotkeys.stop()
            lifeLogMiniWindowHotkeys.stop()
            voiceMemoHotkeys.stop()
        } else {
            startHotkeyMonitor()
        }
    }

    public func updateHotkey(_ binding: HotkeyBinding) {
        guard binding != settings.lifeLogCaptureHotkey,
              binding != settings.lifeLogMiniWindowHotkey,
              binding != settings.voiceMemoHotkey else {
            hotkeyError = String(lore: "同じキーを複数の操作には割り当てられません")
            return
        }
        settings.hotkey = binding
        hotkeys.update(binding: binding)
        startHotkeyMonitor()
    }

    public func updateLifeLogCaptureHotkey(_ binding: HotkeyBinding) {
        guard binding != settings.hotkey,
              binding != settings.lifeLogMiniWindowHotkey,
              binding != settings.voiceMemoHotkey else {
            hotkeyError = String(lore: "同じキーを複数の操作には割り当てられません")
            return
        }
        settings.lifeLogCaptureHotkey = binding
        lifeLogCaptureHotkeys.update(binding: binding)
        hotkeyError = nil
        startHotkeyMonitor()
    }

    public func updateLifeLogMiniWindowHotkey(_ binding: HotkeyBinding) {
        guard binding != settings.hotkey,
              binding != settings.lifeLogCaptureHotkey,
              binding != settings.voiceMemoHotkey else {
            hotkeyError = String(lore: "同じキーを複数の操作には割り当てられません")
            return
        }
        settings.lifeLogMiniWindowHotkey = binding
        lifeLogMiniWindowHotkeys.update(binding: binding)
        hotkeyError = nil
        startHotkeyMonitor()
    }

    public func updateVoiceMemoHotkey(_ binding: HotkeyBinding) {
        guard binding != settings.hotkey,
              binding != settings.lifeLogCaptureHotkey,
              binding != settings.lifeLogMiniWindowHotkey else {
            hotkeyError = String(lore: "同じキーを複数の操作には割り当てられません")
            return
        }
        settings.voiceMemoHotkey = binding
        voiceMemoHotkeys.update(binding: binding)
        hotkeyError = nil
        startHotkeyMonitor()
    }

    public func toggleVoiceMemo() {
        if coordinator.isVoiceMemoRecording {
            coordinator.stop()
            return
        }
        guard !coordinator.isBusy, !isPreparingVoiceMemo else { return }
        isPreparingVoiceMemo = true
        Task { [weak self] in
            guard let self else { return }
            let suspended = await lifeLog.suspendForVoiceMemo()
            guard suspended else {
                lifeLog.resumeAfterVoiceMemo()
                isPreparingVoiceMemo = false
                return
            }
            let started = coordinator.startVoiceMemo(
                onRecognized: { [weak self] text in await self?.lifeLog.addMemo(text) },
                onFinished: { [weak self] in self?.lifeLog.resumeAfterVoiceMemo() }
            )
            if !started { lifeLog.resumeAfterVoiceMemo() }
            isPreparingVoiceMemo = false
        }
    }

    public var canToggleVoiceMemo: Bool {
        coordinator.isVoiceMemoRecording || (!coordinator.isBusy && !isPreparingVoiceMemo)
    }

    public func applyLifeLogMiniWindowLevel() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == LoreWindow.lifeLogMini }) else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
    }

    // MARK: 権限

    public var requiresInputMonitoring: Bool {
        [
            settings.hotkey,
            settings.lifeLogCaptureHotkey,
            settings.lifeLogMiniWindowHotkey,
            settings.voiceMemoHotkey,
        ].contains { binding in
            guard case .key(_, let modifiers) = binding else { return false }
            return HotkeyMonitor.requiresInputMonitoring(modifiers: modifiers)
        }
    }

    public func refreshPermissions() {
        isAccessibilityGranted = Permissions.isAccessibilityGranted
        isInputMonitoringGranted = Permissions.isInputMonitoringGranted
        isMicrophoneGranted = Permissions.isMicrophoneGranted
        isCalendarGranted = Permissions.isCalendarGranted
        // 画面を開いたタイミングは「権限を付与した直後」の可能性が高いので、監視を焚き直す。
        if !isAccessibilityGranted || !isMicrophoneGranted || (requiresInputMonitoring && !isInputMonitoringGranted) {
            startPermissionWatcher()
        }
    }

    /// 未確認ならシステムのダイアログを出し、一度拒否されていればシステム設定の該当箇所を開く。
    /// 押しても何も起きない「許可する」を作らないため、拒否済みの経路もここで扱う。
    public func requestMicrophone() async {
        switch Permissions.microphoneStatus {
        case .denied, .restricted:
            Permissions.openMicrophoneSettings()
        default:
            _ = await Permissions.requestMicrophone()
        }
        refreshPermissions()
    }

    public func requestCalendar() async {
        if Permissions.canPromptForCalendar {
            await lifeLog.loadCalendars()
        } else if !Permissions.isCalendarGranted {
            Permissions.openCalendarSettings()
        }
        refreshPermissions()
    }

    public func requestAccessibility() {
        Permissions.requestAccessibility()
    }

    public func requestInputMonitoring() {
        _ = Permissions.requestInputMonitoring()
        refreshPermissions()
        if isInputMonitoringGranted {
            startHotkeyMonitor()
        }
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
            LoreLog.ui.error("ログイン項目の変更に失敗: \(error.localizedDescription, privacy: .public)")
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
        guard !isAccessibilityGranted || !isMicrophoneGranted || (requiresInputMonitoring && !isInputMonitoringGranted) else { return }
        guard permissionWatcher == nil else { return }
        permissionWatcher = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.permissionWatcher = nil } }
            for _ in 0..<Self.permissionWatchAttempts {
                try? await Task.sleep(for: Self.permissionWatchInterval)
                guard let self, !Task.isCancelled else { return }
                let hadAccessibility = isAccessibilityGranted
                let hadInputMonitoring = isInputMonitoringGranted
                isAccessibilityGranted = Permissions.isAccessibilityGranted
                isInputMonitoringGranted = Permissions.isInputMonitoringGranted
                isMicrophoneGranted = Permissions.isMicrophoneGranted
                isCalendarGranted = Permissions.isCalendarGranted
                if (!hadAccessibility && isAccessibilityGranted)
                    || (!hadInputMonitoring && isInputMonitoringGranted)
                {
                    startHotkeyMonitor()
                }
                if isAccessibilityGranted,
                   isMicrophoneGranted,
                   !requiresInputMonitoring || isInputMonitoringGranted
                { return }
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
            LoreLog.persistence.error("モードの読み込みに失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 共通ルール

    public func reloadSharedRules() async {
        guard let database else { return }
        do {
            sharedRules = try await database.sharedRules.current()
        } catch {
            LoreLog.persistence.error("共通ルールの読み込みに失敗: \(error.localizedDescription, privacy: .public)")
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
        copy.name = String(lore: "\(mode.name) のコピー")
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
        } catch {
            LoreLog.persistence.error("語彙の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
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

    // MARK: 履歴

    public func reloadHistory(query: String = "") async {
        guard let database else { return }
        do {
            history = try await database.history.search(query: query, limit: 300)
            historyCount = try await database.history.count()
            latency = try await database.history.latencyStats(limit: 100)
            measuredLatencies = try await database.history.measuredLatencies(limit: 300)
        } catch {
            LoreLog.persistence.error("履歴の読み込みに失敗: \(error.localizedDescription, privacy: .public)")
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
                LoreLog.persistence.info("保持期間超過の履歴を \(removed, privacy: .public) 件削除しました")
                await reloadHistory()
            }
        } catch {
            reportDataOperation(error)
        }
    }

    /// 他のMacの変更を取り込んだ後、開いている画面を読み直す。
    private func reloadAfterSync() async {
        await reloadHistory()
        // 語彙は次の録音sessionから使う。取り込みのたびに記録中の認識を再起動しない。
        await reloadVocabulary()
        await lifeLog.reload()
        await lifeLog.loadActivity(containing: lifeLog.selectedDate)
    }

    // MARK: 保存データ

    public func purgeExpiredLifeLogAudio() async {
        guard let database else { return }
        let cutoff: Date?
        switch settings.lifeLogAudioRetentionPolicy {
        case .processedOnly:
            cutoff = nil
        case .days(let days):
            guard let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
            cutoff = date
        case .unlimited:
            return
        }
        do {
            for url in try await database.lifeLog.deletableAudioFileURLs(endedBefore: cutoff) {
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
            cancelWhisperDownload()
            try removeLifeLogAudioDirectory()
            try removeWhisperModelsDirectories()
            try SecretStore.deleteAll()
            try database.deleteBackups()
            try await database.deleteAllUserData()
            await sync.didDeleteAllData()
            settings.resetAll()
            engines.apply(
                backend: settings.formattingBackend,
                model: settings.model(for: settings.formattingBackend)
            )
            applySttSelection()
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
                LoreLog.persistence.error("保存容量を確認できません: \(error.localizedDescription, privacy: .public)")
            }
        }
        return total
    }

    private static var appDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lore", isDirectory: true)
    }

    private static var lifeLogAudioRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lore/LifeLog", isDirectory: true)
    }

    private func removeLifeLogAudioDirectory() throws {
        let root = Self.lifeLogAudioRoot
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func removeWhisperModelsDirectories() throws {
        for root in [WhisperCppStt.defaultModelRoot, WhisperCppStt.legacyModelRoot] {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    private func reportDataOperation(_ error: Error) {
        dataOperationError = error.localizedDescription
        LoreLog.persistence.error("保存データの操作に失敗: \(error.localizedDescription, privacy: .public)")
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
            String(lore: "録音の保存処理が終わらなかったため、データを削除しませんでした。もう一度お試しください。")
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
            LoreLog.engine.error("音声モデルの取得に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applySttSelection() {
        engines.applyStt(
            dictation: settings.dictationSttBackend,
            lifeLog: settings.lifeLogSttBackend,
            model: settings.whisperModel
        )
    }

    /// 聞き取りengineかwhisper modelの変更。録音中の音声入力は開始時のengineで最後まで処理する。
    public func applySttChange() async {
        applySttSelection()
        await engines.refreshSttAvailability()
        lifeLog.transcriptionConfigurationDidChange()
    }

    public func applyLifeLogTranscriptionLanguageChange() async {
        await engines.refreshSttAvailability(
            languagePreference: settings.lifeLogTranscriptionLanguage.preference(
                applicationLanguage: settings.applicationLanguage
            )
        )
        lifeLog.transcriptionConfigurationDidChange()
    }

    public func installWhisperModel() {
        guard whisperProgress == nil else { return }
        whisperProgress = 0
        whisperError = nil
        whisperInstallTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await engines.installWhisperModel { progress in
                    Task { @MainActor [weak self] in self?.whisperProgress = progress }
                }
                whisperProgress = nil
                refreshStorageSizes()
            } catch is CancellationError {
                whisperProgress = nil
            } catch {
                whisperProgress = nil
                whisperError = error.localizedDescription
                LoreLog.engine.error("whisper.cppモデルの取得に失敗: \(error.localizedDescription, privacy: .public)")
            }
            whisperInstallTask = nil
        }
    }

    public func cancelWhisperDownload() {
        whisperInstallTask?.cancel()
        whisperInstallTask = nil
        whisperProgress = nil
        whisperError = nil
    }

    /// 使用中のjobがあるmodelは削除しない。音声入力とライフログの両方で共有している。
    public var isWhisperModelInUse: Bool {
        lifeLog.hasCaptureIntent || lifeLog.isTranscribing || coordinator?.isBusy == true
    }

    public func deleteWhisperModel() async {
        guard !isWhisperModelInUse else { return }
        whisperError = nil
        do {
            try await engines.deleteWhisperModel()
            refreshStorageSizes()
        } catch {
            whisperError = error.localizedDescription
            LoreLog.engine.error("whisper.cppモデルの削除に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func reloadMeasuredLatencies() async {
        guard let database else { return }
        measuredLatencies = (try? await database.history.measuredLatencies(limit: 300)) ?? MeasuredLatencies()
    }

    public func applyEngineChange(
        checkCredentials: Bool = true,
        resetConnectionState: Bool = false
    ) async {
        applySttSelection()
        let backend = settings.formattingBackend
        engines.apply(backend: backend, model: settings.model(for: backend))
        if resetConnectionState {
            llmModels = []
            llmStatus = nil
        }
        if checkCredentials {
            do {
                hasLlmApiKey = if let key = secretKey(for: backend) {
                    try SecretStore.read(key)?.isEmpty == false
                } else {
                    true
                }
            } catch {
                hasLlmApiKey = false
                llmStatus = error.localizedDescription
                LoreLog.engine.error("API キーの確認に失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
        await engines.refreshSttAvailability()
        if checkCredentials || backend == .onDevice {
            await engines.refreshLlmAvailability()
        }
    }

    // MARK: 文章処理エンジン

    /// API キーを Keychain に保存する(空文字なら削除)。値は保持しない。
    public func setLlmApiKey(_ key: String) async {
        guard let secretKey = secretKey(for: settings.formattingBackend) else { return }
        llmStatus = nil
        do {
            try SecretStore.write(key, for: secretKey)
        } catch {
            llmStatus = error.localizedDescription
            LoreLog.engine.error("API キーの保存に失敗: \(error.localizedDescription, privacy: .public)")
            return
        }
        llmModels = []
        await applyEngineChange()
    }

    /// キーとモデルが実際に通るかを 1 往復して確かめる。
    ///
    /// 整形は失敗しても生テキストにフォールバックするので、設定ミスは
    /// 「なんとなく仕上がらない」形でしか表に出ない。ここで明示的に確かめられるようにする。
    public func checkLlmConnection() async {
        guard !isCheckingLlm else { return }
        isCheckingLlm = true
        llmStatus = nil
        defer { isCheckingLlm = false }

        do {
            let backend = settings.formattingBackend
            llmModels = try await engines.availableModels(for: backend)
            let reply = try await engines.llm.complete(
                prompt: FormattingPrompt(system: "入力をそのまま返してください。", user: "疎通確認"),
                timeout: .seconds(20)
            )
            llmStatus = reply.isEmpty
                ? String(lore: "接続できましたが、応答が空でした")
                : String(lore: "\(settings.model(for: backend)) に接続できました")
        } catch {
            llmStatus = error.localizedDescription
            LoreLog.engine.error("LLM の疎通確認に失敗: \(error.localizedDescription, privacy: .public)")
        }
        await engines.refreshLlmAvailability()
    }

    private func secretKey(for backend: FormattingBackend) -> SecretStore.Key? {
        switch backend {
        case .openAI: .openAIApiKey
        case .anthropic: .anthropicApiKey
        case .gemini: .geminiApiKey
        case .groq: .groqApiKey
        case .onDevice, .ollama, .lmStudio: nil
        }
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
