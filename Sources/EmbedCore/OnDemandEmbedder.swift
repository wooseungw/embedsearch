import Foundation

/// Holds a model that is loaded on first use and released after `idleTimeout` without use, so a
/// resident app pays for its memory only while it is being used. Concurrent users share one load,
/// and the model is never released while a `use` is running.
public actor OnDemandModel<Model: Sendable> {
    public nonisolated let idleTimeout: Duration
    private let load: @Sendable () async throws -> Model
    private let didUnload: @Sendable () -> Void

    private var model: Model?
    private var loading: Task<Model, Error>?
    private var inFlight = 0
    private var lastUse = ContinuousClock.now
    private var unloadTimer: Task<Void, Never>?
    /// Identifies the current timer; a release bumps it, so a stale timer can only exit.
    private var timerID = 0
    /// When the last load failed; `prepare` starts none for `failedLoadPause` after it.
    private var lastFailure: ContinuousClock.Instant?
    private let failedLoadPause: Duration = .seconds(600)

    /// Number of completed loads (diagnostics and tests).
    public private(set) var loadCount = 0
    public var isLoaded: Bool { model != nil }

    /// - Parameters:
    ///   - preloaded: an already loaded model; it is released after `idleTimeout` like a loaded one.
    ///   - load: loads the model; called again after every release.
    ///   - didUnload: runs after the model was released, e.g. to return freed GPU buffers.
    public init(idleTimeout: Duration, preloaded: Model? = nil,
                load: @escaping @Sendable () async throws -> Model,
                didUnload: @escaping @Sendable () -> Void = {}) {
        self.idleTimeout = idleTimeout
        self.load = load
        self.didUnload = didUnload
        self.model = preloaded
        if preloaded != nil { Task { await self.touch() } }
    }

    /// Runs `body` with the model, loading it first if needed.
    public func use<R: Sendable>(_ body: @Sendable (Model) async throws -> R) async throws -> R {
        inFlight += 1
        defer {
            inFlight -= 1
            touch()
        }
        let model = try await loadedModel()
        return try await body(model)
    }

    /// Runs `body` with the model if one is loaded or being loaded (waiting for that load);
    /// returns nil without starting a load otherwise.
    public func useIfLoaded<R: Sendable>(_ body: @Sendable (Model) async throws -> R) async throws -> R? {
        guard model != nil || loading != nil else { return nil }
        return try await use(body)
    }

    /// Starts loading in the background if needed (so a later `use` does not wait for the whole
    /// load) and restarts the idle clock. Within `failedLoadPause` of a failed load it starts none:
    /// a `use` still retries at once, but loads ahead of need do not repeat a failing one.
    public func prepare() {
        touch()
        guard model == nil else { return }
        if let lastFailure, ContinuousClock.now - lastFailure < failedLoadPause { return }
        _ = startLoading()
    }

    /// Restarts the idle clock if a model is loaded; never starts a load (e.g. when the search UI
    /// opens on battery: a loaded model stays for the coming queries, but none is loaded for
    /// queries that may not need it).
    public func keepAlive() {
        if model != nil { touch() }
    }

    /// Releases the model now unless a `use` or a load is running. Returns whether it did.
    @discardableResult
    public func unload() -> Bool {
        guard model != nil, inFlight == 0, loading == nil else { return false }
        release()
        return true
    }

    private func loadedModel() async throws -> Model {
        if let model { return model }
        return try await startLoading().value
    }

    private func startLoading() -> Task<Model, Error> {
        if let loading { return loading }
        let task = Task { () throws -> Model in
            do {
                let loaded = try await load()
                finishLoading(loaded)
                return loaded
            } catch {
                finishLoading(nil)
                throw error
            }
        }
        loading = task
        return task
    }

    private func finishLoading(_ loaded: Model?) {
        loading = nil
        lastFailure = loaded == nil ? .now : nil
        if let loaded {
            model = loaded
            loadCount += 1
        }
        touch()
    }

    /// Marks a use and (re)arms the idle timer while a model is held.
    private func touch() {
        lastUse = .now
        guard model != nil, unloadTimer == nil else { return }
        timerID += 1
        unloadTimer = Task { [weak self, idleTimeout, timerID] in
            var wait = idleTimeout
            while true {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                guard let remaining = await self.unloadIfIdle(timer: timerID) else { return }
                wait = remaining
            }
        }
    }

    /// Releases the model if it has been idle for `idleTimeout`; otherwise returns how much longer
    /// to wait. Nil when this timer is done (released, or superseded).
    private func unloadIfIdle(timer: Int) -> Duration? {
        guard timer == timerID, model != nil else { return nil }
        let idle = ContinuousClock.now - lastUse
        if inFlight > 0 || loading != nil || idle < idleTimeout {
            return max(idleTimeout - idle, .milliseconds(10))
        }
        release()
        return nil
    }

    private func release() {
        model = nil
        timerID += 1
        unloadTimer?.cancel()
        unloadTimer = nil
        didUnload()
    }
}

/// A `TextEmbedder` whose model is loaded on first use and released after `idleTimeout` without
/// use (see `OnDemandModel`).
///
/// `info` is known up front (remembered from an earlier load), so cached vectors stay usable while
/// the model is unloaded; only embedding a query or a new item loads it. A load whose `info`
/// differs from the expected one fails with `OnDemandEmbedderError.modelChanged`: its vectors would
/// not be comparable with the cached ones.
///
/// While its model is not loaded, texts go to `standIn` if that one is loaded (or loading): the
/// vision model, which embeds text into the same space, so a query during indexing does not load a
/// second copy of the text weights next to it (~0.8 GB).
public struct OnDemandEmbedder: TextEmbedder {
    public let info: EmbeddingModelInfo
    public let model: OnDemandModel<any TextEmbedder>
    /// Nil when none was given, or when its `info` is not `info`.
    public let standIn: OnDemandImageEmbedder?

    public init(info: EmbeddingModelInfo, idleTimeout: Duration, preloaded: (any TextEmbedder)? = nil,
                standIn: OnDemandImageEmbedder? = nil,
                load: @escaping @Sendable () async throws -> any TextEmbedder,
                didUnload: @escaping @Sendable () -> Void = {}) {
        self.info = info
        self.standIn = standIn?.info == info ? standIn : nil
        model = OnDemandModel(idleTimeout: idleTimeout, preloaded: preloaded, load: {
            let loaded = try await load()
            try OnDemandEmbedderError.check(loaded.info, expected: info)
            return loaded
        }, didUnload: didUnload)
    }

    public func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        if inputs.isEmpty { return [] }
        if let standIn, !(await model.isLoaded) {
            do {
                if let vectors = try await standIn.embedIfLoaded(inputs) { return vectors }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The stand-in failed (e.g. its load did): this model does the work.
            }
        }
        return try await model.use { try await $0.embed(inputs) }
    }

    public func prepare() async { await model.prepare() }
    public func keepAlive() async { await model.keepAlive() }
    @discardableResult public func unload() async -> Bool { await model.unload() }
    public var isLoaded: Bool { get async { await model.isLoaded } }
    public var loadCount: Int { get async { await model.loadCount } }
}

/// An `ImageEmbedder` whose model is loaded on first use and released after `idleTimeout` without
/// use; like `OnDemandEmbedder`, a load with a different `info` fails.
public struct OnDemandImageEmbedder: ImageEmbedder {
    public let info: EmbeddingModelInfo
    public let model: OnDemandModel<any ImageEmbedder>

    public init(info: EmbeddingModelInfo, idleTimeout: Duration,
                load: @escaping @Sendable () async throws -> any ImageEmbedder,
                didUnload: @escaping @Sendable () -> Void = {}) {
        self.info = info
        model = OnDemandModel(idleTimeout: idleTimeout, load: {
            let loaded = try await load()
            try OnDemandEmbedderError.check(loaded.info, expected: info)
            return loaded
        }, didUnload: didUnload)
    }

    public func embed(images: [ImageInput]) async throws -> [[Float]] {
        if images.isEmpty { return [] }
        return try await model.use { try await $0.embed(images: images) }
    }

    public func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        if inputs.isEmpty { return [] }
        return try await model.use { try await $0.embed(inputs) }
    }

    /// Embeds `inputs` if the model is loaded or being loaded; nil (no load) otherwise.
    public func embedIfLoaded(_ inputs: [EmbeddingInput]) async throws -> [[Float]]? {
        if inputs.isEmpty { return [] }
        return try await model.useIfLoaded { try await $0.embed(inputs) }
    }

    @discardableResult public func unload() async -> Bool { await model.unload() }
    public var isLoaded: Bool { get async { await model.isLoaded } }
}

public enum OnDemandEmbedderError: Error, LocalizedError {
    /// The loaded model is not the one whose vectors are cached (e.g. a newer checkpoint).
    case modelChanged(expected: EmbeddingModelInfo, loaded: EmbeddingModelInfo)

    static func check(_ loaded: EmbeddingModelInfo, expected: EmbeddingModelInfo) throws {
        guard loaded == expected else { throw modelChanged(expected: expected, loaded: loaded) }
    }

    public var errorDescription: String? {
        switch self {
        case .modelChanged(let expected, let loaded):
            "The embedding model changed (\(expected.cacheKey) → \(loaded.cacheKey))"
        }
    }
}
