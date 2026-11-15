// Accessibility driver for the verification skill. Drives only LoreUITests.app
// (bundle ID dev.agatan.Lore.UIE2E), which always runs on an in-memory database.
// Built and invoked through scripts/lore-verify; do not run it directly.
import AppKit
import ApplicationServices
import Foundation

let testBundleID = "dev.agatan.Lore.UIE2E"
let stateDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LORE_VERIFY_STATE"]!)
let pidFile = stateDir.appendingPathComponent("pid")
let runFile = stateDir.appendingPathComponent("current-run")

struct Failure: Error, CustomStringConvertible { let description: String }

func fail(_ message: String) -> Failure { Failure(description: message) }

/// While the login screen is up, AX resolves every window to the application element, so no window content is visible.
func screenIsLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

// MARK: - Run bookkeeping

func currentRunDir() throws -> URL {
    guard let path = try? String(contentsOf: runFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty else { throw fail("no current run; start one with `lore-verify launch`") }
    return URL(fileURLWithPath: path)
}

func log(_ line: String) {
    print(line)
    guard let dir = try? currentRunDir() else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "\(stamp) \(line)\n"
    let file = dir.appendingPathComponent("transcript.log")
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data(entry.utf8))
        try? handle.close()
    } else {
        try? entry.write(to: file, atomically: true, encoding: .utf8)
    }
}

func recordedApp() throws -> NSRunningApplication {
    guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw fail("no instance recorded; run `lore-verify launch` first")
    }
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        throw fail("recorded pid \(pid) is not running; run `lore-verify launch` again")
    }
    guard app.bundleIdentifier == testBundleID else {
        throw fail("pid \(pid) belongs to \(app.bundleIdentifier ?? "unknown"), not \(testBundleID); refusing to drive it")
    }
    return app
}

// MARK: - Accessibility tree

func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

/// macOS 26 maps a CFArray cast to `[AXUIElement]` onto a single element, so read entries one by one.
func children(_ name: String, of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
          let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
    let array = unsafeBitCast(value, to: CFArray.self)
    return (0..<CFArrayGetCount(array)).map {
        Unmanaged<AXUIElement>.fromOpaque(CFArrayGetValueAtIndex(array, $0)!).takeUnretainedValue()
    }
}

func actions(of element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func descendants(_ root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var pending = [root]
    var visited: Set<CFHashCode> = []
    while let element = pending.popLast(), result.count < 8_000 {
        guard visited.insert(CFHash(element)).inserted else { continue }
        result.append(element)
        pending.append(contentsOf: children(kAXChildrenAttribute as String, of: element).reversed())
    }
    return result
}

func identifier(_ element: AXUIElement) -> String? { attribute(kAXIdentifierAttribute as String, of: element) }
func stringValue(_ element: AXUIElement) -> String? { attribute(kAXValueAttribute as String, of: element) }
func title(_ element: AXUIElement) -> String? { attribute(kAXTitleAttribute as String, of: element) }

func describe(_ element: AXUIElement) -> String? {
    let role: String? = attribute(kAXRoleAttribute as String, of: element)
    let id = identifier(element), t = title(element), v = stringValue(element)
    let acts = actions(of: element)
    guard id != nil || t != nil || (v.map { !$0.isEmpty } ?? false) || !acts.isEmpty else { return nil }
    let shortValue = v.map { $0.count > 160 ? String($0.prefix(160)) + "…" : $0 }?.replacingOccurrences(of: "\n", with: "⏎")
    return "role=\(role ?? "-") id=\(id ?? "-") title=\(t ?? "-") value=\(shortValue ?? "-") actions=\(acts.joined(separator: ","))"
}

func waitFor(_ what: String, timeout: TimeInterval, in app: NSRunningApplication, _ predicate: (AXUIElement) -> Bool) throws -> AXUIElement {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let match = descendants(root).first(where: predicate) { return match }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    } while Date() < deadline
    throw fail("timed out after \(timeout)s waiting for \(what); run `lore-verify tree` to see what is on screen")
}

func element(id: String, timeout: TimeInterval, in app: NSRunningApplication) throws -> AXUIElement {
    try waitFor("id=\(id)", timeout: timeout, in: app) { identifier($0) == id }
}

// MARK: - Windows and screenshots

func windowIDs(pid: pid_t) -> [(id: CGWindowID, name: String)] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { entry in
        guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let layer = entry[kCGWindowLayer as String] as? Int, layer < 20, // normal + floating panels, not menu bar
              ((entry[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 40,
              let number = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
        return (number, entry[kCGWindowName as String] as? String ?? "")
    }
}

func screenshot(app: NSRunningApplication, name: String) throws {
    let dir = try currentRunDir()
    let windows = windowIDs(pid: app.processIdentifier)
    guard !windows.isEmpty else { throw fail("no on-screen windows for pid \(app.processIdentifier)") }
    for (index, window) in windows.enumerated() {
        let file = dir.appendingPathComponent(windows.count == 1 ? "\(name).png" : "\(name)-\(index).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.id)", file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            throw fail("screencapture failed for window \(window.id); grant Screen Recording to the terminal")
        }
        log("shot \(file.path) window=\"\(window.name)\"")
    }
}

// MARK: - Commands

func launch(_ appPath: String, _ extra: [String]) async throws {
    if let app = try? recordedApp() {
        throw fail("instance pid \(app.processIdentifier) from the previous launch is still running; run `lore-verify stop` first")
    }
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID)
    if !others.isEmpty {
        throw fail("another LoreUITests instance is running (pid \(others.map(\.processIdentifier))), probably `make ui-test` or another agent; wait for it instead of driving it")
    }
    let url = URL(fileURLWithPath: appPath)
    guard Bundle(url: url)?.bundleIdentifier == testBundleID else { throw fail("\(appPath) is not the UI test bundle; run `lore-verify build`") }
    guard !screenIsLocked() else { throw fail("the screen is locked; AX cannot see window contents until the user unlocks it") }

    var ready = "life-log.capture-toggle"
    var arguments: [String] = []
    var iterator = extra.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--demo": arguments.append("--lore-screenshot-demo")
        case "--empty": arguments.append("--lore-ui-test-empty")
        case "--settings":
            guard let section = iterator.next() else { throw fail("--settings needs privacy|calendar|life-log|life-log-ai|modes|dictation") }
            arguments.append("--lore-ui-test-settings-\(section)")
            ready = "settings.section.privacy"
        case "--lang":
            guard let lang = iterator.next() else { throw fail("--lang needs en|ja|zh-Hans") }
            arguments += ["--lore-demo-language", lang]
        case "--ready":
            guard let id = iterator.next() else { throw fail("--ready needs an accessibility identifier") }
            ready = id
        default: arguments.append(arg)
        }
    }

    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let runDir = stateDir.appendingPathComponent("evidence/\(stamp.string(from: Date()))")
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    try runDir.path.write(to: runFile, atomically: true, encoding: .utf8)

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = arguments
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    configuration.allowsRunningApplicationSubstitution = false
    let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    guard app.bundleIdentifier == testBundleID else { throw fail("launched process is \(app.bundleIdentifier ?? "unknown")") }
    try String(app.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    log("launch pid=\(app.processIdentifier) args=\(arguments.joined(separator: " "))")
    _ = try element(id: ready, timeout: 20, in: app)
    log("ready id=\(ready)")
    print("run dir: \(runDir.path)")
}

func stop() {
    guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        print("nothing to stop")
        return
    }
    defer { try? FileManager.default.removeItem(at: pidFile) }
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        print("pid \(pid) already exited")
        return
    }
    guard app.bundleIdentifier == testBundleID else {
        print("pid \(pid) now belongs to \(app.bundleIdentifier ?? "unknown"); leaving it alone")
        return
    }
    app.terminate()
    let deadline = Date().addingTimeInterval(3)
    while !app.isTerminated, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    if !app.isTerminated { app.forceTerminate() }
    log("stop pid=\(pid)")
}

func doctor(_ appPath: String) {
    var ok = true
    func check(_ pass: Bool, _ label: String, _ hint: String = "") {
        print("\(pass ? "ok  " : "FAIL") \(label)\(pass || hint.isEmpty ? "" : " — \(hint)")")
        if !pass { ok = false }
    }
    let url = URL(fileURLWithPath: appPath)
    check(Bundle(url: url)?.bundleIdentifier == testBundleID, "test bundle at \(appPath)", "run `lore-verify build`")
    check(AXIsProcessTrusted(), "terminal has Accessibility permission", "System Settings > Privacy & Security > Accessibility")
    check(CGPreflightScreenCaptureAccess(), "terminal has Screen Recording permission (for `shot`)", "only screenshots need it")
    check(!screenIsLocked(), "screen is unlocked", "AX cannot see window contents on the lock screen; wait for the user to unlock")
    let binary = url.appendingPathComponent("Contents/MacOS/Lore")
    let built = (try? FileManager.default.attributesOfItem(atPath: binary.path)[.modificationDate] as? Date) ?? .distantPast
    let sources = FileManager.default.enumerator(atPath: "Sources")
    var newest = Date.distantPast
    var newestFile = ""
    while let file = sources?.nextObject() as? String {
        if let date = try? FileManager.default.attributesOfItem(atPath: "Sources/\(file)")[.modificationDate] as? Date, date > newest {
            newest = date
            newestFile = file
        }
    }
    check(built >= newest, "build is newer than Sources/", "Sources/\(newestFile) changed after the build; run `lore-verify build`")
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID)
    if let app = try? recordedApp() {
        check(true, "recorded instance pid \(app.processIdentifier) is running")
        check(running.count == 1, "exactly one LoreUITests instance", "pids \(running.map(\.processIdentifier)); another driver is active")
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = children(kAXWindowsAttribute as String, of: root)
        let windowRoles = windows.map { (attribute(kAXRoleAttribute as String, of: $0) as String?) ?? "-" }
        check(!windows.isEmpty && windowRoles.allSatisfy { $0 != kAXApplicationRole as String },
              "accessibility tree shows \(windows.count) window(s)", "windows resolve as \(windowRoles); the app is still booting or the screen is locked")
        print("     windows: \(windowIDs(pid: app.processIdentifier).map { "\($0.id) \"\($0.name)\"" }.joined(separator: ", "))")
    } else {
        print("info no instance recorded (pids running for test bundle: \(running.map(\.processIdentifier)))")
    }
    if let dir = try? currentRunDir() { print("info current run dir \(dir.path)") }
    exit(ok ? 0 : 1)
}

@MainActor
func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { print("see .claude/skills/verify/SKILL.md"); exit(2) }
    let rest = Array(args.dropFirst())
    func arg(_ index: Int, _ label: String) throws -> String {
        guard rest.indices.contains(index) else { throw fail("\(command): missing \(label)") }
        return rest[index]
    }
    let timeout = TimeInterval(ProcessInfo.processInfo.environment["LORE_VERIFY_TIMEOUT"] ?? "") ?? 8
    do {
        switch command {
        case "launch": try await launch(try arg(0, "app path"), Array(rest.dropFirst()))
        case "stop": stop()
        case "doctor": doctor(try arg(0, "app path"))
        case "tree":
            let app = try recordedApp()
            let filter = rest.first
            let lines = descendants(AXUIElementCreateApplication(app.processIdentifier)).compactMap(describe)
            for line in lines where filter.map(line.contains) ?? true { print(line) }
        case "wait":
            let id = try arg(0, "identifier")
            _ = try element(id: id, timeout: timeout, in: try recordedApp())
            log("wait id=\(id) ok")
        case "absent":
            let id = try arg(0, "identifier")
            let app = try recordedApp()
            let present = descendants(AXUIElementCreateApplication(app.processIdentifier)).contains { identifier($0) == id }
            guard !present else { throw fail("absent id=\(id): element is present") }
            log("absent id=\(id) ok")
        case "press":
            let id = try arg(0, "identifier")
            let target = try element(id: id, timeout: timeout, in: try recordedApp())
            // AXPress on a static text "succeeds" without doing anything, so require the action to exist.
            guard actions(of: target).contains(kAXPressAction as String) else {
                throw fail("press id=\(id): element has no AXPress (actions: \(actions(of: target))); for list/sidebar rows use `select`")
            }
            guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { throw fail("press id=\(id): AXPress failed") }
            log("press id=\(id)")
        case "menu":
            let name = try arg(0, "menu item title")
            let item = try waitFor("menu item \"\(name)\"", timeout: timeout, in: try recordedApp()) {
                (attribute(kAXRoleAttribute as String, of: $0) as String?) == kAXMenuItemRole as String && title($0) == name
            }
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { throw fail("menu \"\(name)\": AXPress failed") }
            log("menu \"\(name)\"")
        case "hover":
            // Moves the real pointer. Needed for controls that SwiftUI only shows on hover (opacity 0 hides them from AX).
            let key = try arg(0, "identifier or exact text")
            let scope = rest.count > 2 && rest[1] == "--in" ? rest[2] : nil
            func windowName(_ element: AXUIElement) -> String {
                guard let window: AXUIElement = attribute(kAXWindowAttribute as String, of: element) else { return "?" }
                return identifier(window) ?? title(window) ?? "?"
            }
            func matches(_ element: AXUIElement) -> Bool {
                guard identifier(element) == key || title(element) == key || stringValue(element) == key else { return false }
                guard let scope, let window: AXUIElement = attribute(kAXWindowAttribute as String, of: element) else { return true }
                return identifier(window) == scope || title(window) == scope
            }
            let app = try recordedApp()
            _ = try waitFor("id or text \"\(key)\"\(scope.map { " in window \($0)" } ?? "")", timeout: timeout, in: app, matches)
            let found = descendants(AXUIElementCreateApplication(app.processIdentifier)).filter(matches)
            let windows = Set(found.map(windowName))
            guard windows.count == 1, let target = found.first else {
                throw fail("hover \(key): matches in several windows \(windows.sorted()); add `--in <window id or title>`")
            }
            try recordedApp().activate()
            if let window: AXUIElement = attribute(kAXWindowAttribute as String, of: target) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target, kAXPositionAttribute as CFString, &positionRef) == .success,
                  AXUIElementCopyAttributeValue(target, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let positionRef, let sizeRef else { throw fail("hover \(key): element has no frame") }
            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(unsafeBitCast(positionRef, to: AXValue.self), .cgPoint, &origin)
            AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
            let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            // CGWindowList is front-to-back: the first normal/floating window containing the point receives the hover.
            let front = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .first { entry in
                    guard let layer = entry[kCGWindowLayer as String] as? Int, layer < 20,
                          let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                    return rect.contains(point)
                }
            let targetWindowTitle: String? = (attribute(kAXWindowAttribute as String, of: target) as AXUIElement?).flatMap(title)
            if let front, (front[kCGWindowOwnerPID as String] as? pid_t) != app.processIdentifier
                || (front[kCGWindowName as String] as? String) != targetWindowTitle {
                throw fail("hover \(key): point \(Int(point.x)),\(Int(point.y)) is covered by window \"\(front[kCGWindowName as String] as? String ?? "?")\" of \(front[kCGWindowOwnerName as String] as? String ?? "?"); close or move it first")
            }
            CGWarpMouseCursorPosition(point)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            log("hover \(key) at \(Int(point.x)),\(Int(point.y))")
        case "select":
            let id = try arg(0, "identifier")
            var current: AXUIElement? = try element(id: id, timeout: timeout, in: try recordedApp())
            while let node = current, (attribute(kAXRoleAttribute as String, of: node) as String?) != kAXRowRole as String {
                current = attribute(kAXParentAttribute as String, of: node)
            }
            guard let row = current,
                  AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw fail("select id=\(id): no selectable AXRow ancestor")
            }
            log("select id=\(id)")
        case "set":
            let id = try arg(0, "identifier"), text = try arg(1, "text")
            let target = try element(id: id, timeout: timeout, in: try recordedApp())
            guard AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFString) == .success else {
                throw fail("set id=\(id): AXValue not settable")
            }
            log("set id=\(id) text=\(text)")
        case "value":
            let id = try arg(0, "identifier")
            let value = stringValue(try element(id: id, timeout: timeout, in: try recordedApp())) ?? ""
            log("value id=\(id) =>")
            print(value)
            if let dir = try? currentRunDir() {
                try value.write(to: dir.appendingPathComponent("value-\(id).txt"), atomically: true, encoding: .utf8)
            }
        case "expect":
            let id = try arg(0, "identifier"), needle = try arg(1, "substring")
            let negate = rest.count > 2 && rest[2] == "--not"
            _ = try waitFor("id=\(id) value \(negate ? "without" : "containing") \"\(needle)\"", timeout: timeout, in: try recordedApp()) {
                guard identifier($0) == id, let value = stringValue($0) else { return false }
                return value.contains(needle) != negate
            }
            log("expect id=\(id) \(negate ? "lacks" : "contains") \"\(needle)\" ok")
        case "text":
            let needle = try arg(0, "text")
            _ = try waitFor("title or value == \"\(needle)\"", timeout: timeout, in: try recordedApp()) {
                title($0) == needle || stringValue($0) == needle
            }
            log("text \"\(needle)\" visible ok")
        case "shot": try screenshot(app: try recordedApp(), name: try arg(0, "name"))
        default: throw fail("unknown command \(command)")
        }
    } catch {
        log("FAIL \(command) \(rest.joined(separator: " ")): \(error)")
        exit(1)
    }
}

await main()
