import Foundation
import Hub
import WhisperKit

/// モデルの取得・配置・削除。
///
/// **アプリ内で唯一ネットワークに触れるモジュール**(NFR-2)。
/// 他のモジュールから URLSession / HubApi を直接呼ばないことを規約とする。
/// エンジン側は `download: false` で構成し、取得は必ずここを通す。
public enum ModelStore {
    public static var rootDirectory: URL {
        applicationSupport.appendingPathComponent("models", isDirectory: true)
    }

    public static var whisperDirectory: URL {
        rootDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    public static var mlxDirectory: URL {
        rootDirectory.appendingPathComponent("mlx", isDirectory: true)
    }

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Koe", isDirectory: true)
    }

    /// MLX 用の Hub。ダウンロード先を Koe の中に閉じ込める。
    public static var mlxHub: HubApi {
        HubApi(downloadBase: mlxDirectory)
    }

    // MARK: WhisperKit

    /// 取得済みの CoreML モデルフォルダ。無ければ nil。
    public static func whisperModelFolder(variant: String) -> URL? {
        let candidates = [
            whisperDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)"),
            whisperDirectory.appendingPathComponent(variant),
        ]
        return candidates.first { hasContents(at: $0) }
    }

    public static func isDownloaded(whisperVariant: String) -> Bool {
        whisperModelFolder(variant: whisperVariant) != nil
    }

    public static func downloadWhisper(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: whisperDirectory, withIntermediateDirectories: true)
        return try await WhisperKit.download(
            variant: variant,
            downloadBase: whisperDirectory,
            useBackgroundSession: false
        ) { fraction in
            progress(fraction.fractionCompleted)
        }
    }

    // MARK: MLX

    public static func mlxModelFolder(id: String) -> URL? {
        let folder = mlxDirectory.appendingPathComponent("models/\(id)")
        return hasContents(at: folder) ? folder : nil
    }

    public static func isDownloaded(mlxModelID: String) -> Bool {
        mlxModelFolder(id: mlxModelID) != nil
    }

    // MARK: 共通

    public static func delete(directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public static func deleteWhisper(variant: String) throws {
        guard let folder = whisperModelFolder(variant: variant) else { return }
        try delete(directory: folder)
    }

    public static func deleteMlx(id: String) throws {
        guard let folder = mlxModelFolder(id: id) else { return }
        try delete(directory: folder)
    }

    /// モデルが占めているディスク容量。
    public static func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }

    /// 中身のあるディレクトリかどうか(途中で失敗した空フォルダを「取得済み」と誤認しない)。
    static func hasContents(at url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return !contents.isEmpty
    }
}
