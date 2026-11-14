#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// 開発用: `--lore-screenshot-demo --lore-record <dir>`で起動すると、LP用の短い動画を
/// 決まった台本で再生しながら自process内のwindowだけを収録し、終了する。Release buildには含めない。
@MainActor
enum DebugRecorder {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--lore-record"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(env: AppEnvironment, presenter: LoreWindowPresenter, into directory: URL) async {
        // 台本は発話をdatabaseへ書き足すため、利用者データと分離したdemo databaseでだけ動かす。
        guard ProcessInfo.processInfo.arguments.contains("--lore-screenshot-demo") else {
            FileHandle.standardError.write(Data("収録は --lore-screenshot-demo と一緒に指定してください\n".utf8))
            exit(1)
        }
        if let appearance = DebugSnapshotter.appearance { NSApp.appearance = appearance }
        env.settings.applicationLanguage = DemoCopy.current.language
        let suffix = DebugSnapshotter.appearance?.name == .darkAqua ? "-dark" : ""
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await recordDictation(env: env, to: directory.appending(path: "dictation\(suffix).mp4"))
            try await recordLifeLog(env: env, to: directory.appending(path: "life-log\(suffix).mp4"))
        } catch {
            FileHandle.standardError.write(Data("収録に失敗: \(error.localizedDescription)\n".utf8))
        }
        exit(0)
    }

    // MARK: Dictation

    /// 書きかけのメモへ、話した言葉が整って入るまで。
    private static func recordDictation(env: AppEnvironment, to url: URL) async throws {
        guard let coordinator = env.coordinator else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "音声入力の状態機械がまだありません"])
        }
        let script = DictationDemoScript()
        let window = hostedWindow(
            DictationDemoScene(script: script, hud: HudView(coordinator: coordinator, onCancel: {})),
            size: NSSize(width: 880, height: 520),
            identifier: "lore.record.dictation"
        )
        defer { window.orderOut(nil) }
        coordinator.applyPreviewState(phase: .idle)
        await settle(1)

        let spoken = DemoCopy.current.spoken
        let formatted = DemoCopy.current.formatted
        var levels = [Float](repeating: 0.05, count: DictationCoordinator.levelHistoryLength)
        try await record(window: window, to: url) {
            await settle(0.8)
            let start = ContinuousClock.now
            let speaking: Duration = .seconds(4.2)
            var tick = 0
            while ContinuousClock.now - start < speaking + .seconds(0.4) {
                let elapsed = ContinuousClock.now - start
                let progress = min(1, elapsed / speaking)
                tick += 1
                let voice = progress < 1 ? 0.25 + 0.6 * abs(sin(Double(tick) / 3.1)) * abs(cos(Double(tick) / 7.3)) : 0.04
                levels.removeFirst()
                levels.append(Float(voice))
                coordinator.applyPreviewState(
                    phase: .recording,
                    transcript: String(spoken.prefix(Int(Double(spoken.count) * progress))),
                    mode: BuiltinModes.defaultMode,
                    levels: levels,
                    elapsed: elapsed,
                    inputDeviceName: DemoCopy.current.inputDevice
                )
                await settle(1.0 / 30.0)
            }
            coordinator.applyPreviewState(phase: .formatting, transcript: spoken, mode: BuiltinModes.defaultMode)
            await settle(1.3)
            coordinator.applyPreviewState(phase: .finished(.completed), mode: BuiltinModes.defaultMode)
            for count in 1...formatted.count {
                script.inserted = String(formatted.prefix(count))
                await settle(0.012)
            }
            await settle(1.4)
            coordinator.applyPreviewState(phase: .idle)
            await settle(1.2)
        }
    }

    // MARK: Life log

    /// 記録を始めると、話した言葉が一日のtimelineへ順に積み上がる。
    private static func recordLifeLog(env: AppEnvironment, to url: URL) async throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == LoreWindow.main }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "main windowが表示されていません"])
        }
        env.mainSection = .lifeLog
        window.makeKeyAndOrderFront(nil)
        await env.lifeLog.followCurrentDay()
        await settle(1.5)

        let sentences = DemoCopy.current.liveSentences
        try await record(window: window, to: url) {
            await settle(0.8)
            env.lifeLog.applyPreviewCapture(capturing: true)
            await settle(1.2)
            for sentence in sentences {
                let startedAt = Date()
                let speaking = 3.2
                let steps = 60
                for step in 1...steps {
                    let progress = Double(step) / Double(steps)
                    env.lifeLog.applyPreviewCapture(
                        capturing: true,
                        hearingSince: startedAt,
                        audioDuration: speaking * progress,
                        transcript: String(sentence.prefix(Int(Double(sentence.count) * progress)))
                    )
                    await settle(speaking / Double(steps))
                }
                await settle(0.5)
                env.lifeLog.applyPreviewCapture(capturing: true)
                try await env.lifeLog.savePreviewUtterance(text: sentence, startedAt: startedAt, endedAt: Date())
                await settle(1.6)
            }
            await settle(1.0)
        }
        env.lifeLog.applyPreviewCapture(capturing: false)
    }

    // MARK: Recording

    private static func hostedWindow(_ view: some View, size: NSSize, identifier: String) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.contentView = hosting
        window.level = .floating
        window.center()
        window.orderFrontRegardless()
        return window
    }

    private static func record(window: NSWindow, to url: URL, perform script: () async throws -> Void) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "収録するwindowを取得できません"])
        }
        // 単独windowの収録ではsystemが信号機の位置へ収録中の印を重ねるため、
        // 画面全体から自windowだけを残して切り抜く。
        guard let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.displays.first else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "収録するdisplayを取得できません"])
        }
        let filter = SCContentFilter(display: display, including: [target])
        let scale = window.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: target.frame.minX - display.frame.minX,
            y: target.frame.minY - display.frame.minY,
            width: target.frame.width,
            height: target.frame.height
        )
        configuration.width = Int(target.frame.width * scale)
        configuration.height = Int(target.frame.height * scale)
        configuration.backgroundColor = .clear
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        configuration.capturesAudio = false

        try? FileManager.default.removeItem(at: url)
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = url
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264
        let finished = RecordingFinished()
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: finished)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        do {
            try await script()
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        try await finished.wait()
    }

    private static func settle(_ seconds: Double) async {
        do { try await Task.sleep(for: .seconds(seconds)) } catch {}
    }
}

/// SCRecordingOutputの完了をasyncで待つ。
private final class RecordingFinished: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { resolve(.success(())) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { resolve(.failure(error)) }

    private func resolve(_ value: Result<Void, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: value)
        } else {
            result = value
            lock.unlock()
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

@MainActor
@Observable
private final class DictationDemoScript {
    var inserted = ""
}

/// 音声入力の収録用の机。落ち着いた無地の背景に書きかけのメモを置き、下にHUDを浮かべる。
private struct DictationDemoScene: View {
    var script: DictationDemoScript
    var hud: HudView

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.86, green: 0.86, blue: 0.88)
            note
                .padding(.horizontal, 110)
                .padding(.top, 56)
                .padding(.bottom, 150)
                .frame(maxHeight: .infinity, alignment: .top)
            hud
                .frame(width: 560, height: 160, alignment: .bottom)
                .padding(.bottom, 26)
        }
        .environment(\.colorScheme, .light)
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.black.opacity(0.14)).frame(width: 11, height: 11) }
                Spacer()
                Text(verbatim: DemoCopy.current.messageTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 47, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                message(name: DemoCopy.current.messageFrom, text: DemoCopy.current.messageText)
                HStack(alignment: .top, spacing: 10) {
                    avatar(String(DemoCopy.current.me.prefix(1)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: DemoCopy.current.me).font(.system(size: 13, weight: .semibold))
                        (Text(verbatim: script.inserted) + Text(verbatim: "|").foregroundColor(Color.primary.opacity(0.6)))
                            .font(.system(size: 14))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.08)))
        .foregroundStyle(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    private func message(name: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(String(name.prefix(1)))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name).font(.system(size: 13, weight: .semibold))
                Text(verbatim: text).font(.system(size: 14))
            }
        }
    }

    private func avatar(_ letter: String) -> some View {
        Text(verbatim: letter)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
#endif
