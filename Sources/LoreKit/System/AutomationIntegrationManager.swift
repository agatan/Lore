import Foundation

public enum AutomationIntegrationState: Equatable, Sendable {
    case unavailable(String)
    case notInstalled
    case installed
    case updateAvailable
    case conflict(String)
}

public struct AutomationIntegrationStatus: Equatable, Sendable {
    public var cli: AutomationIntegrationState
    public var skill: AutomationIntegrationState

    public static let unavailable = Self(
        cli: .unavailable("Lore.appにCLIが同梱されていません"),
        skill: .unavailable("Lore.appにAgent Skillが同梱されていません")
    )
}

/// Lore.app内のCLIとSkillを、ユーザーが管理しやすい安定した場所へ公開する。
/// シェル設定は変更せず、Loreが作ったリンクとSkillだけを更新対象にする。
public struct AutomationIntegrationManager: Sendable {
    public let bundleURL: URL
    public let homeDirectory: URL

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.bundleURL = bundleURL
        self.homeDirectory = homeDirectory
    }

    public var cliSourceURL: URL {
        bundleURL.appending(path: "Contents/Helpers/lore")
    }

    public var cliDestinationURL: URL {
        homeDirectory.appending(path: ".local/bin/lore")
    }

    public var skillSourceURL: URL {
        bundleURL.appending(path: "Contents/Resources/Skills/lore")
    }

    public var skillDestinationURL: URL {
        homeDirectory.appending(path: ".agents/skills/lore")
    }

    public var claudeSkillURL: URL {
        homeDirectory.appending(path: ".claude/skills/lore")
    }

    public func status() -> AutomationIntegrationStatus {
        .init(cli: cliState(), skill: skillState())
    }

    public func installCLI() throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: cliSourceURL.path) else {
            throw Failure.missingBundledCLI
        }
        try fileManager.createDirectory(
            at: cliDestinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch entry(at: cliDestinationURL) {
        case .missing:
            break
        case .symbolicLink:
            try fileManager.removeItem(at: cliDestinationURL)
        case .other:
            throw Failure.unmanagedFile(cliDestinationURL.path)
        }
        try fileManager.createSymbolicLink(at: cliDestinationURL, withDestinationURL: cliSourceURL)
    }

    public func installSkill() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: skillSourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.missingBundledSkill
        }

        try preflightManagedSkill()
        try preflightClaudeLink()

        let parent = skillDestinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".lore-stage-\(UUID().uuidString)")
        let backup = parent.appending(path: ".lore-backup-\(UUID().uuidString)")
        defer {
            removeTemporaryItem(staged)
            removeTemporaryItem(backup)
        }

        try fileManager.copyItem(at: skillSourceURL, to: staged)
        try Self.managedMarker.write(to: staged.appending(path: Self.markerName), atomically: true, encoding: .utf8)

        let hadExistingSkill = entry(at: skillDestinationURL) != .missing
        if hadExistingSkill {
            try fileManager.moveItem(at: skillDestinationURL, to: backup)
        }
        do {
            try fileManager.moveItem(at: staged, to: skillDestinationURL)
        } catch let installError {
            if hadExistingSkill {
                do {
                    try fileManager.moveItem(at: backup, to: skillDestinationURL)
                } catch {
                    throw Failure.skillRecoveryFailed(
                        install: installError.localizedDescription,
                        recovery: error.localizedDescription
                    )
                }
            }
            throw installError
        }

        try fileManager.createDirectory(
            at: claudeSkillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if entry(at: claudeSkillURL) == .symbolicLink {
            try fileManager.removeItem(at: claudeSkillURL)
        }
        try fileManager.createSymbolicLink(at: claudeSkillURL, withDestinationURL: skillDestinationURL)
    }

    private func cliState() -> AutomationIntegrationState {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: cliSourceURL.path) else {
            return .unavailable("Lore.appにCLIが同梱されていません")
        }
        switch entry(at: cliDestinationURL) {
        case .missing:
            return .notInstalled
        case .symbolicLink:
            return linkDestination(at: cliDestinationURL) == cliSourceURL.standardizedFileURL
                ? .installed : .updateAvailable
        case .other:
            return .conflict("同名のファイルがすでにあります")
        }
    }

    private func skillState() -> AutomationIntegrationState {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: skillSourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable("Lore.appにAgent Skillが同梱されていません")
        }
        switch entry(at: skillDestinationURL) {
        case .missing:
            return .notInstalled
        case .symbolicLink, .other:
            guard isManagedSkill else {
                return .conflict("同名のSkillがすでにあります")
            }
        }

        guard entry(at: claudeSkillURL) != .other else {
            return .conflict("Claudeに同名のSkillがあります")
        }
        guard directoriesMatch(skillSourceURL, skillDestinationURL),
              linkDestination(at: claudeSkillURL) == skillDestinationURL.standardizedFileURL else {
            return .updateAvailable
        }
        return .installed
    }

    private func preflightManagedSkill() throws {
        switch entry(at: skillDestinationURL) {
        case .missing:
            return
        case .symbolicLink, .other:
            guard isManagedSkill else { throw Failure.unmanagedFile(skillDestinationURL.path) }
        }
    }

    private func preflightClaudeLink() throws {
        switch entry(at: claudeSkillURL) {
        case .missing:
            return
        case .symbolicLink:
            guard linkDestination(at: claudeSkillURL) == skillDestinationURL.standardizedFileURL else {
                throw Failure.unmanagedFile(claudeSkillURL.path)
            }
        case .other:
            throw Failure.unmanagedFile(claudeSkillURL.path)
        }
    }

    private var isManagedSkill: Bool {
        FileManager.default.fileExists(atPath: skillDestinationURL.appending(path: Self.markerName).path)
    }

    private func directoriesMatch(_ source: URL, _ destination: URL) -> Bool {
        guard let sourceFiles = regularFiles(in: source), let destinationFiles = regularFiles(in: destination),
              sourceFiles == destinationFiles.subtracting([Self.markerName]) else { return false }
        return sourceFiles.allSatisfy { relativePath in
            let sourceData = try? Data(contentsOf: source.appending(path: relativePath))
            let destinationData = try? Data(contentsOf: destination.appending(path: relativePath))
            return sourceData != nil && sourceData == destinationData
        }
    }

    private func regularFiles(in directory: URL) -> Set<String>? {
        var files: Set<String> = []
        func collect(_ current: URL, relativeTo relativePath: String) throws {
            for fileURL in try FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                let childPath = relativePath.isEmpty ? fileURL.lastPathComponent : "\(relativePath)/\(fileURL.lastPathComponent)"
                if values.isDirectory == true {
                    try collect(fileURL, relativeTo: childPath)
                } else if values.isRegularFile == true {
                    files.insert(childPath)
                }
            }
        }
        do {
            try collect(directory, relativeTo: "")
            return files
        } catch {
            return nil
        }
    }

    private enum Entry: Equatable { case missing, symbolicLink, other }

    private func entry(at url: URL) -> Entry {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return .missing }
        return type == .typeSymbolicLink ? .symbolicLink : .other
    }

    private func linkDestination(at url: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appending(path: destination)
        return resolved.standardizedFileURL
    }

    private static let markerName = ".lore-managed"
    private static let managedMarker = "This Agent Skill is managed by Lore.app.\n"

    private func removeTemporaryItem(_ url: URL) {
        guard entry(at: url) != .missing else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LoreLog.ui.error("連携インストールの一時ファイルを削除できません: \(url.path, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    public enum Failure: LocalizedError {
        case missingBundledCLI
        case missingBundledSkill
        case unmanagedFile(String)
        case skillRecoveryFailed(install: String, recovery: String)

        public var errorDescription: String? {
            switch self {
            case .missingBundledCLI:
                "Lore.appにCLIが同梱されていません。アプリを入れ直してください。"
            case .missingBundledSkill:
                "Lore.appにAgent Skillが同梱されていません。アプリを入れ直してください。"
            case .unmanagedFile(let path):
                "\(path) はLoreが管理していないため、上書きしません。"
            case .skillRecoveryFailed(let install, let recovery):
                "Agent Skillの更新と復元に失敗しました。更新: \(install) / 復元: \(recovery)"
            }
        }
    }
}
