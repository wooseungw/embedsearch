import Foundation
import Darwin

/// Drains both streams during execution, retaining at most one MiB each. Cancellation
/// terminates and reaps the direct child; descendant process lifetimes remain the tool's responsibility.
enum Shell {
    struct Failure: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let stderr: String
        var description: String { "\(command) exited \(status): \(stderr)" }
    }
    struct TimedOut: Error {}

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) async throws -> String {
        let execution = Execution(executable, arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { execution.start($0) }
        } onCancel: { execution.stop(timedOut: false) }
    }

    static func osascript(_ source: String) async throws {
        try await run("/usr/bin/osascript", ["-e", source], timeout: 120)
    }

    /// Lifecycle fields are locked. Each capture has one reader, joined before its data is read.
    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let stdout = Pipe(), stderr = Pipe()
        private let command: String
        private let timeout: TimeInterval?
        private var started = false
        private var finished = false
        private var stopped: Bool? // true: timeout; false: cancellation
        private var continuation: CheckedContinuation<String, Error>?

        init(_ executable: String, _ arguments: [String], timeout: TimeInterval?) {
            command = ([executable] + arguments).joined(separator: " ")
            self.timeout = timeout
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
        }

        func start(_ continuation: CheckedContinuation<String, Error>) {
            lock.withLock { self.continuation = continuation }
            DispatchQueue.global(qos: .userInitiated).async { self.execute() }
        }

        func stop(timedOut: Bool) {
            lock.withLock {
                guard !finished else { return }
                if stopped == nil { stopped = timedOut }
                if started, process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
                lock.withLock {
                    if !finished, started, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                }
            }
        }

        private func execute() {
            let launchError: Error? = lock.withLock {
                if let stopped { return stopped ? TimedOut() : CancellationError() }
                do { try process.run(); started = true; return nil } catch { return error }
            }
            if let launchError { finish(.failure(launchError)); return }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            let timer = DispatchWorkItem { [weak self] in self?.stop(timedOut: true) }
            if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: timer) }
            let out = Capture(), err = Capture(), readers = DispatchGroup()
            for (pipe, capture) in [(stdout, out), (stderr, err)] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    capture.read(pipe.fileHandleForReading)
                    readers.leave()
                }
            }
            process.waitUntilExit()
            timer.cancel()
            out.finishReading()
            err.finishReading()
            readers.wait()
            let result: Result<String, Error> = lock.withLock {
                if let stopped { return .failure(stopped ? TimedOut() : CancellationError()) }
                if process.terminationStatus != 0 {
                    return .failure(Failure(command: command, status: process.terminationStatus, stderr: err.text))
                }
                return .success(out.text)
            }
            finish(result)
        }

        private func finish(_ result: Result<String, Error>) {
            let pending = lock.withLock {
                finished = true
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(with: result)
        }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var finishDeadline: UInt64?
        var text: String { String(decoding: data, as: UTF8.self) }
        func finishReading() {
            lock.withLock { finishDeadline = DispatchTime.now().uptimeNanoseconds + 100_000_000 }
        }
        func read(_ handle: FileHandle) {
            defer { try? handle.close() }
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                // Descendants can inherit pipe writers. Their lifetime must not hold the direct
                // child's completion open; allow a short drain of already-buffered output.
                if lock.withLock({ finishDeadline.map { DispatchTime.now().uptimeNanoseconds >= $0 } ?? false }) { break }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let room = 1_048_576 - data.count
                    if room > 0 { data.append(contentsOf: buffer.prefix(min(room, count))) }
                } else if count == 0 { break }
                else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK {
                    if lock.withLock({ finishDeadline != nil }) { break }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                    _ = poll(&descriptor, 1, 50)
                } else { break }
            }
        }
    }
}
