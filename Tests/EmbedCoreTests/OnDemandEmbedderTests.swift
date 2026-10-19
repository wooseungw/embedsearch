import Foundation
import Synchronization
import Testing
@testable import EmbedCore

private let fakeInfo = EmbeddingModelInfo(modelID: "fake", revision: "r1", dimensions: 2)

/// Returns a fixed vector per input; `delay` makes each call (and so each load) take a while.
private final class FakeEmbedder: TextEmbedder, Sendable {
    let info: EmbeddingModelInfo
    let delay: Duration

    init(info: EmbeddingModelInfo = fakeInfo, delay: Duration = .zero) {
        self.info = info
        self.delay = delay
    }

    func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        if delay > .zero { try await Task.sleep(for: delay) }
        return inputs.map { _ in [1, 0] }
    }
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func makeEmbedder(idle: Duration, loadDelay: Duration = .zero, embedDelay: Duration = .zero,
                          loadedInfo: EmbeddingModelInfo = fakeInfo, failLoads: Int = 0,
                          loads: Counter = Counter(), unloads: Counter = Counter()) -> OnDemandEmbedder {
    OnDemandEmbedder(info: fakeInfo, idleTimeout: idle, load: {
        loads.increment()
        if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
        if loads.count <= failLoads { throw CancellationError() }
        return FakeEmbedder(info: loadedInfo, delay: embedDelay)
    }, didUnload: { unloads.increment() })
}

@Suite("OnDemandEmbedder")
struct OnDemandEmbedderTests {
    @Test func loadsOnFirstUseOnly() async throws {
        let loads = Counter()
        let embedder = makeEmbedder(idle: .seconds(60), loads: loads)
        #expect(await embedder.isLoaded == false)
        #expect(loads.count == 0)
        let out = try await embedder.embed([.query("a"), .query("b")])
        #expect(out == [[1, 0], [1, 0]])
        _ = try await embedder.embed([.query("c")])
        #expect(loads.count == 1)
        #expect(await embedder.isLoaded)
        #expect(try await embedder.embed([]) == [])
    }

    @Test func concurrentCallersShareOneLoad() async throws {
        let loads = Counter()
        let embedder = makeEmbedder(idle: .seconds(60), loadDelay: .milliseconds(50), loads: loads)
        await embedder.prepare()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 { group.addTask { _ = try await embedder.embed([.query("\(i)")]) } }
            try await group.waitForAll()
        }
        #expect(loads.count == 1)
    }

    @Test func releasesAfterIdleAndReloads() async throws {
        let loads = Counter(), unloads = Counter()
        let embedder = makeEmbedder(idle: .milliseconds(100), loads: loads, unloads: unloads)
        _ = try await embedder.embed([.query("a")])
        try await Task.sleep(for: .milliseconds(400))
        #expect(await embedder.isLoaded == false)
        #expect(unloads.count == 1)
        _ = try await embedder.embed([.query("b")])
        #expect(loads.count == 2)
        #expect(await embedder.isLoaded)
    }

    @Test func useKeepsItLoaded() async throws {
        let unloads = Counter()
        let embedder = makeEmbedder(idle: .milliseconds(150), unloads: unloads)
        for _ in 0..<6 {
            _ = try await embedder.embed([.query("a")])
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(unloads.count == 0)
        #expect(await embedder.isLoaded)
    }

    @Test func neverReleasedDuringEmbed() async throws {
        let unloads = Counter()
        let embedder = makeEmbedder(idle: .milliseconds(50), embedDelay: .milliseconds(300), unloads: unloads)
        await embedder.prepare()
        try await Task.sleep(for: .milliseconds(20))  // loaded, idle clock running
        _ = try await embedder.embed([.query("slow")])  // outlives the idle timeout
        #expect(unloads.count == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(unloads.count == 1)
    }

    @Test func preloadedModelIsReleasedWhenUnused() async throws {
        let unloads = Counter()
        let embedder = OnDemandEmbedder(info: fakeInfo, idleTimeout: .milliseconds(50), preloaded: FakeEmbedder(),
                                        load: { FakeEmbedder() }, didUnload: { unloads.increment() })
        #expect(await embedder.isLoaded)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await embedder.isLoaded == false)
        #expect(unloads.count == 1)
    }

    @Test func explicitUnloadAndPrepare() async throws {
        let loads = Counter(), unloads = Counter()
        let embedder = makeEmbedder(idle: .seconds(60), loads: loads, unloads: unloads)
        #expect(await embedder.unload() == false)  // nothing loaded
        await embedder.prepare()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await embedder.isLoaded)
        #expect(await embedder.unload())
        #expect(unloads.count == 1)
        #expect(await embedder.isLoaded == false)
        _ = try await embedder.embed([.query("a")])
        #expect(loads.count == 2)
    }

    @Test func keepAliveNeverLoadsButPostponesRelease() async throws {
        let loads = Counter(), unloads = Counter()
        let embedder = makeEmbedder(idle: .milliseconds(400), loads: loads, unloads: unloads)
        await embedder.keepAlive()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await embedder.loadCount == 0)
        #expect(loads.count == 0)
        #expect(await embedder.isLoaded == false)

        _ = try await embedder.embed([.query("a")])     // released at +400 ms…
        try await Task.sleep(for: .milliseconds(200))
        await embedder.keepAlive()                      // …now at +600 ms
        try await Task.sleep(for: .milliseconds(250))
        #expect(await embedder.isLoaded)
        #expect(unloads.count == 0)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await embedder.isLoaded == false)
        #expect(unloads.count == 1)
        #expect(loads.count == 1)
    }

    @Test func failedLoadIsRetried() async throws {
        let loads = Counter()
        let embedder = makeEmbedder(idle: .seconds(60), failLoads: 1, loads: loads)
        await #expect(throws: CancellationError.self) { try await embedder.embed([.query("a")]) }
        #expect(await embedder.isLoaded == false)
        _ = try await embedder.embed([.query("a")])
        #expect(loads.count == 2)
    }

    @Test func failedPrepareIsNotRepeatedButUseRetries() async throws {
        let loads = Counter()
        let embedder = makeEmbedder(idle: .seconds(60), failLoads: 1, loads: loads)
        await embedder.prepare()
        try await Task.sleep(for: .milliseconds(50))
        #expect(loads.count == 1)
        #expect(await embedder.isLoaded == false)
        await embedder.prepare()
        try await Task.sleep(for: .milliseconds(50))
        #expect(loads.count == 1)
        _ = try await embedder.embed([.query("a")])
        #expect(loads.count == 2)
        #expect(await embedder.isLoaded)
    }

    @Test func differentModelIsRejected() async throws {
        let other = EmbeddingModelInfo(modelID: "fake", revision: "r2", dimensions: 2)
        let embedder = makeEmbedder(idle: .seconds(60), loadedInfo: other)
        await #expect(throws: OnDemandEmbedderError.self) { try await embedder.embed([.query("a")]) }
        #expect(await embedder.isLoaded == false)
    }
}
