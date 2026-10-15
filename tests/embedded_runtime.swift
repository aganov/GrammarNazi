import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

// Exercise the same serialized cancellation/lifetime contract used by the panel.
final class ControlledSession: InferenceSession, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    var events: [String] = [] // confined to worker
    func run(model: URL, request: Data, isCancelled: @escaping () -> Bool) throws -> Data {
        events.append("start")
        started.signal()
        while released.wait(timeout: .now() + 0.01) == .timedOut {
            if isCancelled() { events.append("cancel"); throw CancellationError() }
        }
        events.append("finish")
        return request
    }
}

@main struct InferenceTests {
    static func main() throws {
        let model = URL(fileURLWithPath: "/missing/model.gguf")
        let request = Data(#"{"messages":[],"max_tokens":1}"#.utf8)
        let native = try EmbeddedInferenceSession()
        do {
            _ = try native.run(model: model, request: request, isCancelled: { true })
            fatalError("Pre-cancelled native call ran")
        } catch is CancellationError {}
        require(native.modelLoadCount == 0, "Cancelled load retained weights")
        for data in [Data("{}".utf8), request, Data("\0".utf8)] {
            do {
                _ = try native.run(model: model, request: data, isCancelled: { false })
                fatalError("Invalid request/model succeeded")
            } catch {}
        }
        require(native.modelLoadCount == 0, "Failed load retained weights")
        print("PASS native cancellation, invalid requests, missing model, and repeated failure cleanup")

        let worker = DispatchQueue(label: "test.inference")
        let session = ControlledSession()
        let first = EditingJob(), skipped = EditingJob(), latest = EditingJob()
        let done = DispatchSemaphore(value: 0)
        worker.async {
            do { _ = try first.run(session: session, model: model, request: request); fatalError("Expected cancellation") }
            catch is CancellationError {} catch { fatalError("Unexpected error: \(error)") }
        }
        require(session.started.wait(timeout: .now() + 5) == .success, "Job never started")
        first.cancel(); skipped.cancel()
        worker.async {
            do { _ = try skipped.run(session: session, model: model, request: request); fatalError("Stale job ran") }
            catch is CancellationError {} catch { fatalError("Unexpected error: \(error)") }
            do {
                session.released.signal()
                _ = try latest.run(session: session, model: model, request: request)
                require(session.events == ["start", "cancel", "start", "finish"], "Jobs overlapped or stale job ran")
            } catch { fatalError("Retry failed: \(error)") }
            done.signal()
        }
        require(done.wait(timeout: .now() + 5) == .success, "Cancelled generation blocked retry")
        print("PASS active cancellation, rapid regeneration, stale-job suppression, and retry ordering")

        weak var weakSession: ControlledSession?
        let cleaned = DispatchSemaphore(value: 0)
        worker.async {
            var owned: ControlledSession? = ControlledSession()
            weakSession = owned
            owned = nil
            require(weakSession == nil, "Worker retained closed session")
            cleaned.signal()
        }
        require(cleaned.wait(timeout: .now() + 5) == .success, "Worker cleanup stalled")
        print("PASS session release after worker drains")
    }
}
