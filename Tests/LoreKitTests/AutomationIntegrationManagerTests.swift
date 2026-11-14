import Foundation
import Testing
@testable import LoreKit

@Suite("CLIとAgent Skillのインストール")
struct AutomationIntegrationManagerTests {
    @Test("CLIはPATHを変更せずLore.app内の実体へリンクする")
    func installsAndRepairsCLILink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(fixture.manager.status().cli == .notInstalled)
        try fixture.manager.installCLI()
        #expect(fixture.manager.status().cli == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.manager.cliDestinationURL.path
        ) == fixture.manager.cliSourceURL.path)

        try FileManager.default.removeItem(at: fixture.manager.cliDestinationURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.manager.cliDestinationURL,
            withDestinationURL: fixture.root.appending(path: "old-lore")
        )
        #expect(fixture.manager.status().cli == .updateAvailable)
        try fixture.manager.installCLI()
        #expect(fixture.manager.status().cli == .installed)
    }

    @Test("既存の同名CLIは上書きしない")
    func preservesUnmanagedCLI() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.manager.cliDestinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("user command".utf8).write(to: fixture.manager.cliDestinationURL)

        #expect(fixture.manager.status().cli == .conflict(String(lore: "同名のファイルがすでにあります")))
        #expect(throws: AutomationIntegrationManager.Failure.self) {
            try fixture.manager.installCLI()
        }
        #expect(try String(contentsOf: fixture.manager.cliDestinationURL, encoding: .utf8) == "user command")
    }

    @Test("Skillを共通場所へ配置しClaudeからリンクする")
    func installsAndUpdatesSkill() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(fixture.manager.status().skill == .notInstalled)
        try fixture.manager.installSkill()
        #expect(fixture.manager.status().skill == .installed)
        #expect(try String(
            contentsOf: fixture.manager.skillDestinationURL.appending(path: "SKILL.md"),
            encoding: .utf8
        ) == "version 1")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.manager.claudeSkillURL.path
        ) == fixture.manager.skillDestinationURL.path)

        try "version 2".write(
            to: fixture.manager.skillSourceURL.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        #expect(fixture.manager.status().skill == .updateAvailable)
        try fixture.manager.installSkill()
        #expect(fixture.manager.status().skill == .installed)
        #expect(try String(
            contentsOf: fixture.manager.skillDestinationURL.appending(path: "SKILL.md"),
            encoding: .utf8
        ) == "version 2")
    }

    @Test("既存の同名Skillは上書きしない")
    func preservesUnmanagedSkill() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.manager.skillDestinationURL,
            withIntermediateDirectories: true
        )
        try "user skill".write(
            to: fixture.manager.skillDestinationURL.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        #expect(fixture.manager.status().skill == .conflict(String(lore: "同名のSkillがすでにあります")))
        #expect(throws: AutomationIntegrationManager.Failure.self) {
            try fixture.manager.installSkill()
        }
        #expect(try String(
            contentsOf: fixture.manager.skillDestinationURL.appending(path: "SKILL.md"),
            encoding: .utf8
        ) == "user skill")
    }
}

private final class Fixture {
    let root: URL
    let manager: AutomationIntegrationManager

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "lore-integrations-\(UUID().uuidString)")
        let bundle = root.appending(path: "Lore.app")
        let home = root.appending(path: "home")
        let cli = bundle.appending(path: "Contents/Helpers/lore")
        let skill = bundle.appending(path: "Contents/Resources/Skills/lore")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("cli".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try "version 1".write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        manager = AutomationIntegrationManager(bundleURL: bundle, homeDirectory: home)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
