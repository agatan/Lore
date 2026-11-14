import Foundation
import Testing
@testable import LoreKit

@Suite("旧名Koeのデータ移行")
struct LegacyKoeMigrationTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "lore-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test("新しいfolderがなければ旧folderを丸ごと移し、DBと付随fileを改名する")
    func movesLegacyDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "Koe")
        try write("db", to: legacy.appending(path: "koe.sqlite"))
        try write("wal", to: legacy.appending(path: "koe.sqlite-wal"))
        try write("shm", to: legacy.appending(path: "koe.sqlite-shm"))
        try write("backup", to: legacy.appending(path: "Backups/daily-20261101.sqlite"))
        try write("audio", to: legacy.appending(path: "LifeLog/a.m4a"))

        let outcome = try LegacyKoeMigration.migrateApplicationSupport(in: root)

        #expect(outcome == .moved)
        let current = root.appending(path: "Lore")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try read(current.appending(path: "lore.sqlite")) == "db")
        #expect(try read(current.appending(path: "lore.sqlite-wal")) == "wal")
        #expect(try read(current.appending(path: "lore.sqlite-shm")) == "shm")
        #expect(!FileManager.default.fileExists(atPath: current.appending(path: "koe.sqlite").path))
        #expect(try read(current.appending(path: "Backups/daily-20261101.sqlite")) == "backup")
        #expect(try read(current.appending(path: "LifeLog/a.m4a")) == "audio")
    }

    @Test("旧folderがなければ何もしない")
    func noLegacyDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try LegacyKoeMigration.migrateApplicationSupport(in: root) == .notNeeded)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Lore").path))
    }

    @Test("新旧両方あれば混ぜずに旧folderを残し、その場所を返す")
    func leavesBothWhenCurrentExists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "Koe")
        try write("old", to: legacy.appending(path: "koe.sqlite"))
        try write("new", to: root.appending(path: "Lore/lore.sqlite"))

        let outcome = try LegacyKoeMigration.migrateApplicationSupport(in: root)

        guard case .leftLegacyInPlace(let reported) = outcome else {
            Issue.record("旧folderを残した結果になっていません: \(outcome)")
            return
        }
        #expect(reported.standardizedFileURL.path == legacy.standardizedFileURL.path)
        #expect(try read(legacy.appending(path: "koe.sqlite")) == "old")
        #expect(try read(root.appending(path: "Lore/lore.sqlite")) == "new")
    }

    @Test("移動の後にDBの改名だけが残っていれば、次回に続きから改名する")
    func resumesInterruptedRename() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("db", to: root.appending(path: "Lore/koe.sqlite"))

        #expect(try LegacyKoeMigration.migrateApplicationSupport(in: root) == .notNeeded)
        #expect(try read(root.appending(path: "Lore/lore.sqlite")) == "db")
    }

    @Test("移せなければ例外を返し、旧folderをそのまま残す")
    func failureKeepsLegacyData() throws {
        let root = try makeRoot()
        let legacy = root.appending(path: "Koe")
        try write("db", to: legacy.appending(path: "koe.sqlite"))
        // 親folderを書き込み不可にすると、同じ親の中でのrenameが失敗する。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        #expect(throws: (any Error).self) {
            try LegacyKoeMigration.migrateApplicationSupport(in: root)
        }
        #expect(try read(legacy.appending(path: "koe.sqlite")) == "db")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Lore").path))
    }

    @Test("保存audioのpathを旧folderから新folderへ付け替え、ほかのpathは変えない")
    func rewritesAudioPaths() async throws {
        let database = try await LoreDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_000)
        try await database.lifeLog.save(audioChunk: LifeLogAudioChunk(
            id: "moved", captureStartedAt: start, captureEndedAt: start.addingTimeInterval(30),
            localPath: "/Users/u/Library/Application Support/Koe/LifeLog/2026/a.m4a"
        ))
        try await database.lifeLog.save(audioChunk: LifeLogAudioChunk(
            id: "other", captureStartedAt: start, captureEndedAt: start.addingTimeInterval(30),
            localPath: "/Users/u/Library/Application Support/KoeOther/b.m4a"
        ))

        let changed = try await database.lifeLog.rewriteAudioPaths(
            fromRoot: URL(fileURLWithPath: "/Users/u/Library/Application Support/Koe", isDirectory: true),
            toRoot: URL(fileURLWithPath: "/Users/u/Library/Application Support/Lore", isDirectory: true)
        )

        #expect(changed == 1)
        let paths = Dictionary(uniqueKeysWithValues: try await database.lifeLog.pendingAudioChunks().map { ($0.id, $0.localPath) })
        #expect(paths["moved"] == "/Users/u/Library/Application Support/Lore/LifeLog/2026/a.m4a")
        #expect(paths["other"] == "/Users/u/Library/Application Support/KoeOther/b.m4a")
        // 二度目は該当がなく、何も書かない。
        #expect(try await database.lifeLog.rewriteAudioPaths(
            fromRoot: URL(fileURLWithPath: "/Users/u/Library/Application Support/Koe", isDirectory: true),
            toRoot: URL(fileURLWithPath: "/Users/u/Library/Application Support/Lore", isDirectory: true)
        ) == 0)
    }

    @Test("旧domainの設定を一度だけ写し、設定JSONの鍵名を変える")
    func copiesDefaultsOnce() throws {
        let suite = "lore.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Data("{}".utf8)

        let copied = LegacyKoeMigration.migrateDefaults(
            legacyDomain: ["koe.settings.v1": settings, "lifeLog.showsInspector": false],
            into: defaults
        )

        #expect(copied)
        #expect(defaults.data(forKey: AppSettings.defaultsKey) == settings)
        #expect(defaults.object(forKey: "koe.settings.v1") == nil)
        #expect(defaults.bool(forKey: "lifeLog.showsInspector") == false)
        #expect(defaults.object(forKey: "lifeLog.showsInspector") != nil)
        // 改名後に変えた設定を、旧domainの値で戻さない。
        defaults.set(true, forKey: "lifeLog.showsInspector")
        #expect(!LegacyKoeMigration.migrateDefaults(legacyDomain: ["lifeLog.showsInspector": false], into: defaults))
        #expect(defaults.bool(forKey: "lifeLog.showsInspector"))
    }

    @Test("新しいdomainにすでに設定があれば旧domainを写さない")
    func keepsExistingDefaults() throws {
        let suite = "lore.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = Data("{\"hudEnabled\":false}".utf8)
        defaults.set(current, forKey: AppSettings.defaultsKey)

        #expect(!LegacyKoeMigration.migrateDefaults(legacyDomain: ["koe.settings.v1": Data("{}".utf8)], into: defaults))
        #expect(defaults.data(forKey: AppSettings.defaultsKey) == current)
    }

    /// Keychainの代わりに辞書で持つ。
    private final class FakeKeychain: @unchecked Sendable {
        var items: [String: String] = [:]
        var failingWrites: Set<String> = []

        var backend: LegacyKoeMigration.SecretBackend {
            .init(
                read: { [unowned self] service, account in items["\(service)/\(account)"] },
                write: { [unowned self] service, account, value in
                    if failingWrites.contains(account) { throw CocoaError(.fileWriteNoPermission) }
                    items["\(service)/\(account)"] = value
                },
                delete: { [unowned self] service, account in items["\(service)/\(account)"] = nil }
            )
        }
    }

    @Test("旧serviceのsecretを写して旧itemを消し、新しい値は上書きしない")
    func migratesSecrets() throws {
        let keychain = FakeKeychain()
        keychain.items = [
            "dev.agatan.Koe/openai.apiKey": "old-openai",
            "dev.agatan.Koe/groq.apiKey": "old-groq",
            "dev.agatan.Lore/groq.apiKey": "new-groq",
        ]

        let migrated = try LegacyKoeMigration.migrateSecrets(
            accounts: ["openai.apiKey", "groq.apiKey", "gemini.apiKey"],
            to: "dev.agatan.Lore",
            backend: keychain.backend
        )

        #expect(migrated == ["openai.apiKey"])
        #expect(keychain.items == [
            "dev.agatan.Lore/openai.apiKey": "old-openai",
            "dev.agatan.Lore/groq.apiKey": "new-groq",
        ])
    }

    @Test("写せなかったsecretは旧itemを残して例外で知らせ、ほかは続けて写す")
    func secretFailureKeepsLegacyItem() throws {
        let keychain = FakeKeychain()
        keychain.items = [
            "dev.agatan.Koe/openai.apiKey": "old-openai",
            "dev.agatan.Koe/groq.apiKey": "old-groq",
        ]
        keychain.failingWrites = ["openai.apiKey"]

        #expect(throws: SecretMigrationError.self) {
            try LegacyKoeMigration.migrateSecrets(
                accounts: ["openai.apiKey", "groq.apiKey"],
                to: "dev.agatan.Lore",
                backend: keychain.backend
            )
        }
        #expect(keychain.items["dev.agatan.Koe/openai.apiKey"] == "old-openai")
        #expect(keychain.items["dev.agatan.Lore/groq.apiKey"] == "old-groq")
        #expect(keychain.items["dev.agatan.Koe/groq.apiKey"] == nil)
    }
}
