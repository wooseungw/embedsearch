import Foundation

/// Runs a command-line tool without blocking the main actor.
enum Shell {
    struct Failure: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let stderr: String
        var description: String { "\(command) exited \(status): \(stderr)" }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let outHandle = stdout.fileHandleForReading
            let errHandle = stderr.fileHandleForReading
            let command = ([executable] + arguments).joined(separator: " ")
            process.terminationHandler = { finished in
                let out = String(decoding: outHandle.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: errHandle.readDataToEndOfFile(), as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: Failure(command: command, status: finished.terminationStatus, stderr: err))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func osascript(_ source: String) async throws {
        try await run("/usr/bin/osascript", ["-e", source])
    }
}
