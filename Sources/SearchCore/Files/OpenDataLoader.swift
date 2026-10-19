import Foundation

/// Runs opendataloader-pdf (a Java CLI, Apache-2.0) to read PDFs as structured text: reading order
/// by XY-Cut++, headings, lists and tables, running headers/footers and hidden text removed.
///
/// Each run is one JVM over several files, capped at `maxHeapMB` (its default heap is a quarter of
/// RAM). Some vector-heavy pages exhaust the heap and end the whole run; the CLI reads files in
/// order, so the first one without output is taken as the cause and left to the PDFKit fallback,
/// and the files after it go into a new run. (Retrying every file alone instead made the failing
/// file run twice: on ~/Downloads, 7 such files took 3 of 4 minutes.) Blocking: call it off the
/// main thread and off the cooperative pool.
public struct OpenDataLoader: Sendable {
    public let java: URL
    public let jar: URL
    public var maxHeapMB = 768
    public var filesPerRun = 16
    /// A run is stopped after this long plus `secondsPerFile` per file.
    public var timeoutSeconds = 60.0
    public var secondsPerFile = 20.0

    public init(java: URL, jar: URL) {
        self.java = java
        self.jar = jar
    }

    /// The newest installed Java 11+ (`/usr/libexec/java_home`), with `jar`; nil when either is missing.
    public static func locate(jar: URL) -> OpenDataLoader? {
        guard FileManager.default.fileExists(atPath: jar.path(percentEncoded: false)) else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/libexec/java_home")
        process.arguments = ["-v", "11+"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let home = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty
        else { return nil }
        let java = URL(filePath: home).appending(path: "bin/java")
        guard FileManager.default.isExecutableFile(atPath: java.path(percentEncoded: false)) else { return nil }
        return OpenDataLoader(java: java, jar: jar)
    }

    /// Structures of the PDFs at `paths` that could be read, by path. `progress` gets the number of
    /// files finished so far.
    public func read(_ paths: [String], progress: (Int) -> Void = { _ in }) -> [String: PDFStructure] {
        var out: [String: PDFStructure] = [:]
        var finished = 0
        for batch in Self.batches(paths, size: max(1, filesPerRun)) {
            var pending = batch[...]
            while !pending.isEmpty {
                let results = run(Array(pending))
                out.merge(results) { first, _ in first }
                // Drop everything up to the first file without output (its cause), keep the rest.
                guard let culprit = pending.firstIndex(where: { results[$0] == nil }) else { break }
                pending = pending[(culprit + 1)...].filter { results[$0] == nil }[...]
            }
            finished += batch.count
            progress(finished)
        }
        return out
    }

    /// Splits `paths` into runs of at most `size` whose file names differ: the CLI names each
    /// output after its input's file name.
    static func batches(_ paths: [String], size: Int) -> [[String]] {
        var out: [[String]] = []
        var current: [String] = []
        var names = Set<String>()
        for path in paths {
            let name = (path as NSString).lastPathComponent.lowercased()
            if current.count >= size || names.contains(name) {
                out.append(current)
                current = []
                names = []
            }
            current.append(path)
            names.insert(name)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func run(_ paths: [String]) -> [String: PDFStructure] {
        let outputDir = FileManager.default.temporaryDirectory.appending(path: "embedsearch-odl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            return [:]
        }
        let process = Process()
        process.executableURL = java
        process.arguments = [
            "-Xmx\(maxHeapMB)m", "-XX:+UseSerialGC",
            // No Dock icon, no focus change while the JVM touches AWT imaging.
            "-Djava.awt.headless=true", "-Dapple.awt.UIElement=true",
            "-jar", jar.path(percentEncoded: false),
            "-f", "json", "--image-output", "off", "-q", "-o", outputDir.path(percentEncoded: false),
        ] + paths
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return [:] }
        if done.wait(timeout: .now() + timeoutSeconds + secondsPerFile * Double(paths.count)) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        // Whatever was written is usable, even when the run failed later on.
        var out: [String: PDFStructure] = [:]
        for path in paths {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension + ".json"
            guard let data = try? Data(contentsOf: outputDir.appending(path: name)),
                  let structure = try? PDFStructure.openDataLoaderJSON(data) else { continue }
            out[path] = structure
        }
        return out
    }
}
