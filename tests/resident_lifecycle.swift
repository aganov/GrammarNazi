import Foundation
import Darwin

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

final class MemoryPreferences: ModelPreferences {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class ControlledLoadedSession: LoadedInferenceSession {
    var isModelLoaded = false
    var onPhase: (ModelPhase) -> Void = { _ in }
    let started: DispatchSemaphore
    let finish: DispatchSemaphore
    let destroyed: DispatchSemaphore
    var running = false
    init(started: DispatchSemaphore, finish: DispatchSemaphore, destroyed: DispatchSemaphore) {
        self.started = started; self.finish = finish; self.destroyed = destroyed
    }
    func run(model: URL, request: Data, isCancelled: @escaping () -> Bool) throws -> Data {
        check(!running, "Inference overlapped")
        running = true; defer { running = false }
        if !isModelLoaded { onPhase(.loading); isModelLoaded = true }
        onPhase(.working); started.signal()
        while finish.wait(timeout: .now() + 0.01) == .timedOut {
            if isCancelled() { throw CancellationError() }
        }
        return request
    }
    deinit { check(!running, "Freed an active model"); destroyed.signal() }
}

private func pump(until condition: () -> Bool, timeout: TimeInterval = 3) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(condition(), "Timed out waiting for command routing")
}

@main struct ResidentLifecycleTests {
    static func main() throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--forward" {
            var forwarded = false
            let sender = CommandRouter(action: EditingAction(rawValue: CommandLine.arguments[3])!, lockPath: CommandLine.arguments[2])
            sender.start(onOwner: { fatalError("Child took owner lock") }, onRequest: { _ in }, onForwarded: { forwarded = true }, onFailure: { fatalError($0) })
            pump(until: { forwarded })
            return
        }
        let preferences = MemoryPreferences()
        let state = ModelLifecycle(defaults: preferences)
        var now = Date(timeIntervalSince1970: 1000)
        check(state.minutes == 15, "Default timeout")
        let first = state.openPreview()
        check(state.deadline == nil && state.accepts(first), "Preview started")
        let second = state.openPreview()
        check(!state.accepts(first) && state.accepts(second), "New shortcut invalidates old capture")
        let generation = state.nextGeneration()
        check(!state.accepts(second) && state.accepts(generation), "Late generation cannot overwrite newer result")
        let closed = state.closePreview()
        check(!state.accepts(generation) && state.deadline == nil, "Close clears eligibility before worker drains")
        state.workerDrained(token: first, now: now)
        check(state.idleSince == nil, "Stale worker callback did not start timer")
        now += 100
        state.workerDrained(token: closed, now: now)
        check(state.deadline == now + 900, "Idle starts after cancellation drains")
        for minutes in [5, 15, 30] {
            state.setMinutes(minutes)
            check(state.deadline == now + Double(minutes * 60), "Deadline uses original idle start")
            check(!state.expired(at: now + Double(minutes * 60) - 1), "No early expiry")
            check(state.expired(at: now + Double(minutes * 60)), "Expires at boundary")
            check(state.expired(at: now + 86400), "Expired after sleeping past deadline")
            check(ModelLifecycle(defaults: preferences).minutes == minutes, "Preference survives lifecycle recreation")
        }
        state.setMinutes(0)
        check(state.deadline == nil && !state.expired(at: now + 86400), "Until Quit has no deadline")
        state.setMinutes(30); state.setMinutes(5)
        check(state.expired(at: now + 600), "Shortening timeout can expire immediately")
        state.openPreview()
        check(state.deadline == nil && !state.expired(at: now + 86400), "New edit cancels idle timer")
        state.quit()
        check(!state.accepts(state.generation) && state.deadline == nil, "Quit invalidates all work")
        preferences.values[ModelLifecycle.preferenceKey] = -1
        check(ModelLifecycle(defaults: preferences).minutes == 15, "Invalid saved timeout falls back")
        print("PASS lifecycle generations, fake-clock timeouts, sleep, preference persistence, and Quit")

        // Exercise the production retained-session wrapper on the same queue contract as the app.
        let queue = DispatchQueue(label: "test.resident")
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        var creations = 0
        let resident = ResidentModel {
            creations += 1
            return ControlledLoadedSession(started: started, finish: finish, destroyed: destroyed)
        }
        let path = URL(fileURLWithPath: "/unused.gguf"), data = Data("request".utf8)
        let firstJob = EditingJob()
        queue.async {
            do { _ = try firstJob.run(session: resident, model: path, request: data); fatalError("Expected cancellation") }
            catch is CancellationError {} catch { fatalError("Unexpected error: \(error)") }
        }
        check(started.wait(timeout: .now() + 3) == .success, "Worker started")
        firstJob.cancel()
        queue.async {
            check(resident.isModelLoaded, "Closing preview retained weights")
            finish.signal()
            do { _ = try EditingJob().run(session: resident, model: path, request: data) }
            catch { fatalError("Warm edit failed") }
            check(creations == 1, "Separate edit reused session")
            resident.unload()
            check(!resident.isModelLoaded, "Pressure or quit releases model")
            drained.signal()
        }
        check(drained.wait(timeout: .now() + 3) == .success, "Queue drained")
        check(destroyed.wait(timeout: .now() + 3) == .success, "Session destroyed after work finished")
        queue.sync {
            let cancelled = EditingJob(); cancelled.cancel()
            do { _ = try cancelled.run(session: resident, model: path, request: data); fatalError("Cancelled job ran") }
            catch is CancellationError {} catch { fatalError("Unexpected error") }
            check(creations == 1, "Pre-cancelled work did not reload model")
            finish.signal()
            do { _ = try EditingJob().run(session: resident, model: path, request: data) }
            catch { fatalError("Reload failed") }
            check(creations == 2 && resident.isModelLoaded, "Retry reloads after pressure")
            resident.unload()
        }
        print("PASS resident reuse, cancellation, serialized unload, and reload after memory pressure")

        let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("gn-router-\(UUID()).lock").path
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        var actions: [EditingAction] = [], forwarded = false
        let owner = CommandRouter(action: .grammar, lockPath: lockPath)
        owner.start(onOwner: {}, onRequest: { actions.append($0) }, onForwarded: { fatalError("Owner forwarded") }, onFailure: { fatalError($0) })
        check(owner.ownsLock, "First launch owns lock")
        let sender = CommandRouter(action: .rewrite, lockPath: lockPath)
        sender.start(onOwner: { fatalError("Second launch took lock") }, onRequest: { _ in }, onForwarded: { forwarded = true }, onFailure: { fatalError($0) })
        pump(until: { forwarded && actions.count == 1 })
        check(actions.first == .rewrite, "Requested action forwarded")
        DistributedNotificationCenter.default().postNotificationName(CommandRouter.requestName, object: sender.requestID,
            userInfo: ["action": "rewrite"], deliverImmediately: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        check(actions.count == 1, "Retry deduplicated")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--forward", lockPath, "grammar"]
        try child.run()
        pump(until: { !child.isRunning && actions.count == 2 })
        check(child.terminationStatus == 0 && actions.last == .grammar, "Another process forwarded Grammar")
        owner.stopAccepting()
        var replacementOwned = false
        let replacement = CommandRouter(action: .grammar, lockPath: lockPath)
        replacement.start(onOwner: { replacementOwned = true }, onRequest: { _ in }, onForwarded: { fatalError("Quitting owner acknowledged") }, onFailure: { fatalError($0) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        check(!replacementOwned, "Shutdown keeps lock until cleanup")
        owner.stop()
        pump(until: { replacementOwned })
        var failed = false
        replacement.stopAccepting()
        let unresponsive = CommandRouter(action: .grammar, lockPath: lockPath, timeout: 0.2)
        unresponsive.start(onOwner: { fatalError("Lock stolen") }, onRequest: { _ in }, onForwarded: { fatalError("Unexpected acknowledgment") }, onFailure: { _ in failed = true })
        pump(until: { failed })
        sender.stop(); replacement.stop(); unresponsive.stop()
        // A launcher starts while the future owner still holds its startup lock.
        let startupLock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        check(startupLock >= 0 && flock(startupLock, LOCK_EX | LOCK_NB) == 0, "Startup lock")
        var startupForwarded = false, startupAction: EditingAction?
        let early = CommandRouter(action: .rewrite, lockPath: lockPath)
        early.start(onOwner: { fatalError("Startup lock stolen") }, onRequest: { _ in }, onForwarded: { startupForwarded = true }, onFailure: { fatalError($0) })
        flock(startupLock, LOCK_UN); close(startupLock)
        let late = CommandRouter(action: .grammar, lockPath: lockPath)
        late.start(onOwner: {}, onRequest: { startupAction = $0 }, onForwarded: { fatalError("Late owner forwarded") }, onFailure: { fatalError($0) })
        pump(until: { startupForwarded && startupAction == .rewrite })
        early.stop(); late.stop()
        print("PASS action forwarding, acknowledgment, duplicate suppression, shutdown handoff, and bounded failure")
    }
}
