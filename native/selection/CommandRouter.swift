import Foundation
import Darwin

/// Only command metadata crosses processes; selected text never leaves the owner.
final class CommandRouter {
    static let requestName = Notification.Name("local.grammarnazi.selection.request")
    static let acknowledgmentName = Notification.Name("local.grammarnazi.selection.ack")
    let requestID = UUID().uuidString
    private let center = DistributedNotificationCenter.default()
    private let descriptor: Int32
    private let action: EditingAction
    private let timeout: TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var seen: [String] = []
    private var deadline = Date.distantPast
    private(set) var ownsLock = false
    private var accepting = true
    private var finished = false
    private var onOwner: () -> Void = {}
    private var onRequest: (EditingAction) -> Void = { _ in }
    private var onForwarded: () -> Void = {}
    private var onFailure: (String) -> Void = { _ in }

    init(action: EditingAction, lockPath: String, timeout: TimeInterval = 5) {
        self.action = action; self.timeout = timeout
        descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    }

    func start(onOwner: @escaping () -> Void, onRequest: @escaping (EditingAction) -> Void,
               onForwarded: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
        self.onOwner = onOwner; self.onRequest = onRequest
        self.onForwarded = onForwarded; self.onFailure = onFailure
        guard descriptor >= 0 else { onFailure("Could not open the GrammarNazi instance lock."); return }
        // Observe before taking the lock so a launch during owner startup is retried safely.
        observers.append(center.addObserver(forName: Self.requestName, object: nil, queue: .main) { [weak self] note in
            self?.receive(note)
        })
        observers.append(center.addObserver(forName: Self.acknowledgmentName, object: requestID, queue: .main) { [weak self] _ in
            guard let self, !self.ownsLock, !self.finished else { return }
            self.finished = true; self.timer?.invalidate(); self.onForwarded()
        })
        deadline = Date().addingTimeInterval(timeout)
        attempt()
        if !ownsLock && !finished {
            let retry = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.attempt() }
            timer = retry; RunLoop.main.add(retry, forMode: .common)
        }
    }

    private func attempt() {
        guard !finished, !ownsLock else { return }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            ownsLock = true; timer?.invalidate(); onOwner(); return
        }
        guard Date() < deadline else {
            finished = true; timer?.invalidate()
            onFailure("The running GrammarNazi app did not respond. Quit it and try the command again."); return
        }
        center.postNotificationName(Self.requestName, object: requestID,
                                    userInfo: ["action": action.rawValue], deliverImmediately: true)
    }

    private func receive(_ note: Notification) {
        guard ownsLock, accepting, let id = note.object as? String, UUID(uuidString: id) != nil,
              let raw = note.userInfo?["action"] as? String, let action = EditingAction(rawValue: raw) else { return }
        let duplicate = seen.contains(id)
        if !duplicate {
            seen.append(id)
            if seen.count > 256 { seen.removeFirst() }
        }
        center.postNotificationName(Self.acknowledgmentName, object: id, userInfo: nil, deliverImmediately: true)
        if !duplicate { onRequest(action) }
    }

    func stopAccepting() { accepting = false }
    func stop() {
        accepting = false; finished = true; timer?.invalidate(); timer = nil
        observers.forEach { center.removeObserver($0) }; observers.removeAll()
        if ownsLock { flock(descriptor, LOCK_UN); ownsLock = false }
    }
    deinit { stop(); if descriptor >= 0 { close(descriptor) } }
}
