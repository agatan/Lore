import AVFoundation
import Foundation

/// ライフログ用の一続きのマイク入力。
/// STT向けの連続signalを渡しつつ、復旧用音声を一定間隔でローテーションする。
@MainActor
public final class ContinuousAudioCapture {
    public enum Failure: LocalizedError {
        case alreadyRunning, microphoneDenied, noInputDevice, formatUnsupported, configurationChanged
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: String(lore: "ライフログはすでに記録中です")
            case .microphoneDenied: String(lore: "マイクの使用が許可されていません")
            case .noInputDevice: String(lore: "入力デバイスが見つかりません")
            case .formatUnsupported: String(lore: "この入力フォーマットを変換できません")
            case .configurationChanged: String(lore: "音声入力の構成が変わりました")
            }
        }
    }

    public var onCommitted: (@MainActor @Sendable (LifeLogAudioChunk) async -> Void)?
    public var onFinished: (@MainActor @Sendable () async -> Void)?
    public var onFailure: (@MainActor @Sendable (Error) -> Void)?
    public var onRunningChanged: (@MainActor @Sendable (Bool) -> Void)?
    public private(set) var isRunning = false
    public let chunkDuration: Duration
    public var inputDeviceUID: String?

    private let root: URL
    private let inputEngine = ReusableInputEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var resampler: Resampler?
    private var writer: DurableAudioChunkWriter?
    private var rotationTask: Task<Void, Never>?
    private var configurationObserver: (any NSObjectProtocol)?

    public init(root: URL? = nil, chunkDuration: Duration = .seconds(30)) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lore/LifeLog", isDirectory: true)
        self.chunkDuration = chunkDuration
    }

    public func start(format target: AVAudioFormat) throws -> AsyncStream<AudioChunk> {
        guard !isRunning else { throw Failure.alreadyRunning }
        guard Permissions.isMicrophoneGranted else { throw Failure.microphoneDenied }
        try AudioDevices.selectInput(uid: inputDeviceUID)

        let engine = inputEngine.acquire()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw Failure.noInputDevice }
        guard let resampler = Resampler(from: inputFormat, to: target) else { throw Failure.formatUnsupported }
        guard let writer = DurableAudioChunkWriter(
            root: root,
            inputFormat: inputFormat,
            committed: { [weak self] chunk in Task { @MainActor in await self?.onCommitted?(chunk) } },
            finished: { [weak self] in Task { @MainActor in await self?.onFinished?() } },
            failed: { [weak self] error in Task { @MainActor in self?.recordingFailed(error) } }
        ) else { throw Failure.formatUnsupported }
        try writer.start(at: Date())

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat,
                         block: Self.makeTapBlock(resampler: resampler, continuation: continuation, writer: writer))
        engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        do { try engine.start() } catch {
            inputEngine.discard()
            continuation.finish()
            writer.cancel()
            throw error
        }

        self.continuation = continuation
        self.resampler = resampler
        self.writer = writer
        isRunning = true
        onRunningChanged?(true)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.recordingFailed(Failure.configurationChanged)
            }
        }
        scheduleRotation()
        return stream
    }

    /// 現在までの音声を原子的に確定し、録音を止めずに次のchunkへ進む。
    /// 発話確定後のSTTが30秒rotationを待たず、durable audioを参照するために使う。
    public func checkpoint() {
        guard isRunning else { return }
        writer?.rotate(at: Date())
        scheduleRotation()
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do { try await Task.sleep(for: self.chunkDuration) } catch { return }
                guard self.isRunning else { return }
                self.writer?.rotate(at: Date())
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        onRunningChanged?(false)
        rotationTask?.cancel()
        rotationTask = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        inputEngine.stop()
        continuation?.finish()
        continuation = nil
        resampler = nil
        writer?.finish(at: Date())
        writer = nil
    }

    private nonisolated static func makeTapBlock(
        resampler: Resampler,
        continuation: AsyncStream<AudioChunk>.Continuation,
        writer: DurableAudioChunkWriter
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            writer.append(buffer)
            guard let converted = resampler.convert(buffer) else { return }
            let offset = resampler.advance(by: AVAudioFramePosition(converted.frameLength))
            continuation.yield(AudioChunk(buffer: converted, frameOffset: offset))
        }
    }

    private func recordingFailed(_ error: Error) {
        if isRunning { stop() }
        onFailure?(error)
    }
}

/// リアルタイムスレッドをディスク I/O で止めない直列 writer。
final class DurableAudioChunkWriter: @unchecked Sendable {
    private enum Failure: LocalizedError {
        case conversionFailed
        var errorDescription: String? { String(lore: "ライフログ音声を保存用フォーマットへ変換できません") }
    }

    private let queue = DispatchQueue(label: "app.lore.life-log.audio-writer", qos: .utility)
    private let root: URL
    private let storageFormat = AudioFormats.lifeLogStorage
    private let storageResampler: Resampler
    private let committed: @Sendable (LifeLogAudioChunk) -> Void
    private let finished: @Sendable () -> Void
    private let failed: @Sendable (Error) -> Void
    private var file: AVAudioFile?
    private var partialURL: URL?
    private var startedAt: Date?
    private var failedAlready = false
    private var peakLevel: Float = 0

    init?(root: URL, inputFormat: AVAudioFormat,
         committed: @escaping @Sendable (LifeLogAudioChunk) -> Void,
         finished: @escaping @Sendable () -> Void,
         failed: @escaping @Sendable (Error) -> Void) {
        guard let storageResampler = Resampler(from: inputFormat, to: storageFormat) else { return nil }
        self.root = root
        self.storageResampler = storageResampler
        self.committed = committed
        self.finished = finished
        self.failed = failed
    }

    func start(at date: Date) throws { try queue.sync { try begin(at: date) } }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        let box = AudioBufferBox(copy)
        let level = AudioCapture.level(of: buffer)
        queue.async { [self] in
            guard !failedAlready else { return }
            do {
                peakLevel = max(peakLevel, level)
                guard let converted = storageResampler.convert(box.value) else { throw Failure.conversionFailed }
                try file?.write(from: converted)
            } catch { report(error) }
        }
    }

    func rotate(at date: Date) {
        queue.async { [self] in
            guard !failedAlready else { return }
            do { try commit(endedAt: date); try begin(at: date) } catch { report(error) }
        }
    }

    func finish(at date: Date) {
        queue.async { [self] in
            guard !failedAlready else { return }
            do { try commit(endedAt: date); finished() } catch { report(error) }
        }
    }

    func cancel() {
        queue.sync {
            file = nil
            if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
            partialURL = nil
            startedAt = nil
        }
    }

    private func begin(at date: Date) throws {
        let directory = root.appendingPathComponent(LifeLogDateKey.string(for: date))
            .appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "HH-mm-ss"
        // AVAudioFile は拡張子からコンテナを決めるため、作業中でも末尾は .m4a にする。
        // `.partial.m4a` という名前で完成ファイルとは区別し、commit 時に rename する。
        let partial = directory.appendingPathComponent(formatter.string(from: date) + "-\(UUID().uuidString).partial.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: storageFormat.sampleRate,
                                       AVNumberOfChannelsKey: storageFormat.channelCount,
                                       AVEncoderBitRateKey: 64_000]
        file = try AVAudioFile(forWriting: partial, settings: settings,
                               commonFormat: storageFormat.commonFormat, interleaved: storageFormat.isInterleaved)
        partialURL = partial
        startedAt = date
        peakLevel = 0
    }

    private func commit(endedAt: Date) throws {
        guard let partialURL, let startedAt else { return }
        file = nil
        self.partialURL = nil
        self.startedAt = nil
        let committedURL = URL(fileURLWithPath: partialURL.path.replacingOccurrences(of: ".partial.m4a", with: ".m4a"))
        try FileManager.default.moveItem(at: partialURL, to: committedURL)
        committed(LifeLogAudioChunk(captureStartedAt: startedAt, captureEndedAt: endedAt,
                                    localPath: committedURL.path, peakLevel: peakLevel))
    }

    private func report(_ error: Error) {
        guard !failedAlready else { return }
        failedAlready = true
        file = nil
        failed(error)
        // writer失敗では通常のfinish callbackが走らないため、認識側を待たせない。
        finished()
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData, let destinationData = destinationBuffers[index].mData else { return nil }
            memcpy(destinationData, sourceData, Int(sourceBuffers[index].mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return destination
    }
}

private final class AudioBufferBox: @unchecked Sendable {
    let value: AVAudioPCMBuffer
    init(_ value: AVAudioPCMBuffer) { self.value = value }
}
