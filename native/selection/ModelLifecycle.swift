import Foundation

enum ModelPhase: String { case loading = "Loading…", working = "Working…", ready = "Ready" }

protocol LoadedInferenceSession: InferenceSession {
    var isModelLoaded: Bool { get }
    var onPhase: (ModelPhase) -> Void { get set }
}

/// Confined to the inference worker, including queries and destruction.
final class ResidentModel: InferenceSession {
    private let create: () throws -> LoadedInferenceSession
    private var session: LoadedInferenceSession?
    var onPhase: (ModelPhase) -> Void = { _ in }

    init(create: @escaping () throws -> LoadedInferenceSession) { self.create = create }
    var isModelLoaded: Bool { session?.isModelLoaded == true }
    func unload() { session = nil }

    func run(model: URL, request: Data, isCancelled: @escaping () -> Bool) throws -> Data {
        guard !isCancelled() else { throw CancellationError() }
        if session == nil { session = try create() }
        session!.onPhase = onPhase
        defer { session?.onPhase = { _ in } }
        return try session!.run(model: model, request: request, isCancelled: isCancelled)
    }
}

/// Main-thread state. Passing time explicitly makes sleep and timeout behavior testable.
protocol ModelPreferences {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}
extension UserDefaults: ModelPreferences {}

final class ModelLifecycle {
    static let timeoutChoices = [5, 15, 30, 0]
    static let preferenceKey = "modelIdleMinutes"
    private let defaults: ModelPreferences
    private(set) var minutes: Int
    private(set) var generation = 0
    private(set) var previewOpen = false
    private(set) var quitting = false
    private(set) var idleSince: Date?

    init(defaults: ModelPreferences = UserDefaults.standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.preferenceKey) as? Int
        minutes = saved.flatMap { Self.timeoutChoices.contains($0) ? $0 : nil } ?? 15
    }
    @discardableResult func openPreview() -> Int {
        previewOpen = true; idleSince = nil
        return nextGeneration()
    }
    @discardableResult func nextGeneration() -> Int { generation += 1; return generation }
    func accepts(_ token: Int) -> Bool { !quitting && previewOpen && token == generation }
    @discardableResult func closePreview() -> Int {
        previewOpen = false; idleSince = nil
        return nextGeneration()
    }
    func workerDrained(token: Int, now: Date) {
        guard token == generation, !previewOpen, !quitting else { return }
        idleSince = now
    }
    func setMinutes(_ value: Int) {
        guard Self.timeoutChoices.contains(value) else { return }
        minutes = value; defaults.set(value, forKey: Self.preferenceKey)
    }
    var deadline: Date? { minutes == 0 ? nil : idleSince?.addingTimeInterval(Double(minutes * 60)) }
    func expired(at now: Date) -> Bool { !quitting && !previewOpen && deadline.map { now >= $0 } == true }
    func quit() { quitting = true; idleSince = nil; nextGeneration() }
}
