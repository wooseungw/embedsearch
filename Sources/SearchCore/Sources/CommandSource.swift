import Foundation

/// Built-in commands (`BuiltinCommands`) plus the user's Shortcuts (`/usr/bin/shortcuts list`).
/// Nothing is executed here: the App runs `.builtinCommand` / `.runShortcut` actions.
public struct CommandSource: ItemSource {
    public let name = "commands"
    public var includeShortcuts: Bool
    public var shortcutsTimeout: TimeInterval
    /// Returns shortcut names; injectable for tests. Default runs `shortcuts list` with a timeout.
    public var listShortcuts: @Sendable (TimeInterval) async -> [String]

    public init(includeShortcuts: Bool = true, shortcutsTimeout: TimeInterval = 3,
                listShortcuts: @escaping @Sendable (TimeInterval) async -> [String] = CommandSource.systemShortcuts) {
        self.includeShortcuts = includeShortcuts
        self.shortcutsTimeout = shortcutsTimeout
        self.listShortcuts = listShortcuts
    }

    public func loadItems() async throws -> [SearchItem] {
        var items = BuiltinCommands.all.map(BuiltinCommands.item(for:))
        if includeShortcuts {
            var seen = Set<String>()
            for name in await listShortcuts(shortcutsTimeout) where seen.insert(name).inserted {
                items.append(Self.shortcutItem(name: name))
            }
        }
        return items
    }

    static func shortcutItem(name: String) -> SearchItem {
        SearchItem(
            id: "shortcut:\(name)",
            kind: .shortcut,
            title: name,
            subtitle: "단축어 · Shortcut",
            keywords: ItemText.uniqueKeywords([name]),
            embeddingTitle: name,
            embeddingText: "단축어 (Shortcuts app shortcut) · \(name) 실행 / run shortcut",
            action: .runShortcut(name: name),
            icon: .filePath("/System/Applications/Shortcuts.app")
        )
    }

    /// `shortcuts list` names; empty on any failure or when it does not finish within `timeout`.
    @Sendable
    public static func systemShortcuts(timeout: TimeInterval) async -> [String] {
        guard let output = await run("/usr/bin/shortcuts", ["list"], timeout: timeout) else { return [] }
        return parseShortcutList(output)
    }

    static func parseShortcutList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping }
            .filter { !$0.isEmpty }
    }

    /// Runs a process and returns stdout when it exits with status 0 before `timeout`.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(filePath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
