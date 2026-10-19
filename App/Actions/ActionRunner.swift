import AppKit
import SearchCore
import os

/// Performs a result's `ItemAction`, confirming destructive items first.
@MainActor
final class ActionRunner {
    enum ActionError: Error, CustomStringConvertible {
        case invalidURL(String)
        case openFailed(String)
        var description: String {
            switch self {
            case .invalidURL(let string): return "잘못된 URL: \(string)"
            case .openFailed(let string): return "열 수 없음: \(string)"
            }
        }
    }

    /// Log instead of executing (launch argument `--dry-run-actions`, for UI testing).
    var dryRun = false

    private let commands = BuiltinCommandRunner()
    private let logger = Logger(subsystem: "com.seungwoo.embedsearch", category: "actions")

    /// Returns true when the action ran (false: cancelled at confirmation or failed).
    func run(_ item: SearchItem) async -> Bool {
        if item.requiresConfirmation, !confirm(item) {
            logger.info("cancelled \(item.id, privacy: .public)")
            return false
        }
        if dryRun {
            logger.notice("dry-run \(item.id, privacy: .public): \(String(describing: item.action), privacy: .public)")
            return true
        }
        do {
            try await perform(item.action)
            return true
        } catch {
            logger.error("\(item.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return false
        }
    }

    func perform(_ action: ItemAction) async throws {
        switch action {
        case .openApplication(let path):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
        case .openURL(let string):
            guard let url = URL(string: string) else { throw ActionError.invalidURL(string) }
            guard NSWorkspace.shared.open(url) else { throw ActionError.openFailed(string) }
        case .runShortcut(let name):
            try await Shell.run("/usr/bin/shortcuts", ["run", name])
        case .builtinCommand(let id):
            try await commands.run(id)
        case .openFile(let path):
            guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else { throw ActionError.openFailed(path) }
        }
    }

    private func confirm(_ item: SearchItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "‘\(item.title)’을(를) 실행할까요?"
        alert.informativeText = "이 명령은 되돌릴 수 없거나 열려 있는 앱과 작업에 영향을 줄 수 있습니다."
        let confirmButton = alert.addButton(withTitle: item.title)
        confirmButton.hasDestructiveAction = true
        let cancelButton = alert.addButton(withTitle: "취소")
        cancelButton.keyEquivalent = "\u{1b}"
        return ActiveScreen.runModal(alert) == .alertFirstButtonReturn
    }
}
