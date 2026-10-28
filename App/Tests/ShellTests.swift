import Foundation
import Testing

@Suite("Shell execution", .serialized)
struct ShellTests {
    // A pipe-capacity regression must fail without hanging the test runner: the writer
    // terminates itself after three seconds if its output is never consumed.
    @Test(arguments: ["stdout", "stderr", "both"])
    func largeOutputCompletes(_ destination: String) async {
        let script = """
        import os, signal
        signal.alarm(3)
        data = b'x' * (10 * 1024 * 1024)
        for fd in \(destination == "stdout" ? "[1]" : destination == "stderr" ? "[2]" : "[1, 2]"):
            offset = 0
            while offset < len(data):
                offset += os.write(fd, data[offset:])
        """
        let result = try? await Shell.run("/usr/bin/python3", ["-c", script])
        #expect(result != nil)
        if let result {
            #expect(result.utf8.count == (destination == "stderr" ? 0 : 1_048_576))
        }
    }

    @Test func nonzeroExitIncludesDiagnostic() async {
        do {
            try await Shell.run("/bin/sh", ["-c", "printf diagnostic >&2; exit 7"])
            Issue.record("expected a failed process")
        } catch let error as Shell.Failure {
            #expect(error.status == 7)
            #expect(error.stderr == "diagnostic")
        } catch { Issue.record("wrong error: \(error)") }
    }

    @Test func missingExecutableFails() async {
        let result = try? await Shell.run("/does-not-exist/embedsearch", [])
        #expect(result == nil)
    }

    @Test func inheritedPipesCannotKeepACompletedCommandOpen() async throws {
        let script = """
        import subprocess,sys
        subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(2); print("late descendant output", flush=True)'])
        print('parent complete', flush=True)
        """
        let result = try await Shell.run("/usr/bin/python3", ["-c", script])
        #expect(result == "parent complete\n")
    }

    @Test func timeoutTerminatesAProcessThatIgnoresSIGTERM() async {
        do {
            try await Shell.run("/usr/bin/python3", ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"], timeout: 0.5)
            Issue.record("expected timeout")
        } catch is Shell.TimedOut {} catch { Issue.record("wrong error: \(error)") }
    }

    @Test func cancellationTerminatesTheDirectChild() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "shell-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Task {
            try await Shell.run("/usr/bin/python3", ["-c", "import os,time; open(\"\(file.path)\", 'w').write(str(os.getpid())); time.sleep(30)"])
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var childPID: Int32?
        while childPID == nil, ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8) { childPID = Int32(text) }
            if childPID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch is CancellationError {} catch { Issue.record("wrong error: \(error)") }
        let pid = try #require(childPID)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
