import AppKit

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private func pump(until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(condition(), "App lifecycle check timed out")
}

private final class Preferences: ModelPreferences {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class Control: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    func setBlocked(_ value: Bool) { lock.lock(); blocked = value; lock.unlock() }
    func isBlocked() -> Bool { lock.lock(); defer { lock.unlock() }; return blocked }
}

private final class Session: LoadedInferenceSession {
    var isModelLoaded = false
    var onPhase: (ModelPhase) -> Void = { _ in }
    private let control: Control
    init(_ control: Control) { self.control = control }
    func run(model: URL, request: Data, isCancelled: @escaping () -> Bool) throws -> Data {
        if !isModelLoaded { onPhase(.loading); isModelLoaded = true }
        onPhase(.working)
        while control.isBlocked() {
            if isCancelled() { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if isCancelled() { throw CancellationError() }
        return Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"She has ticket 4821."}}]}"#.utf8)
    }
}

@main struct ResidentAppTests {
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let lifecycle = ModelLifecycle(defaults: Preferences())
        let control = Control()
        var creations = 0, terminated = false, captures = 0
        let resident = ResidentModel { creations += 1; return Session(control) }
        let app = SelectionApp(model: resident, lifecycle: lifecycle, resources: resources, capture: {
            captures += 1
            return CapturedSelection(app: .current, field: nil, window: nil,
                identity: SelectionIdentity(pid: ProcessInfo.processInfo.processIdentifier, text: "She have ticket 4821.", range: nil))
        }, terminate: { terminated = true })
        app.makePanel()
        app.startEdit(.grammar)
        pump(until: { app.result != nil && app.statusItem?.button?.toolTip?.contains("Ready") == true })
        check(app.title.stringValue == EditingAction.grammar.title, "Grammar title")
        check(creations == 1, "First edit loaded one model")
        let menu = app.statusItem!.menu!
        app.menuNeedsUpdate(menu)
        let options = menu.items.first { $0.title == "Keep Model Loaded" }!.submenu!.items
        check(options.map(\.tag) == [5, 15, 30, 0] && options[1].state == .on, "Timeout choices and default")
        app.cancel()
        check(app.captured == nil && app.result == nil, "Closing preview clears selected text and result immediately")
        pump(until: { lifecycle.idleSince != nil })
        app.menuNeedsUpdate(menu)
        check(menu.items.contains { $0.title == "Unloads in 15 minutes" }, "Idle countdown")
        check(menu.items.first { $0.title == "Show Preview" }?.isEnabled == false, "No hidden old preview")
        app.changeTimeout(options[3])
        check(lifecycle.deadline == nil && options[3].state == .on, "Until Quit selection")

        control.setBlocked(true)
        app.startEdit(.grammar)
        pump(until: { app.statusItem?.button?.toolTip?.contains("Working") == true })
        app.startEdit(.rewrite)
        check(app.title.stringValue == EditingAction.rewrite.title && app.result == nil, "Shortcut replaces existing preview and action")
        check(lifecycle.idleSince == nil, "Shortcut cancels idle countdown")
        control.setBlocked(false)
        pump(until: { app.result != nil })
        check(creations == 1 && captures == 3, "Fresh selection, same resident model")

        // Warning preserves a successful result, then unloads when the worker finishes.
        control.setBlocked(true); app.startEdit(.grammar)
        pump(until: { app.statusItem?.button?.toolTip?.contains("Working") == true })
        app.releaseForMemoryPressure(critical: false)
        check(app.statusItem != nil, "Warning does not free an active model immediately")
        control.setBlocked(false)
        pump(until: { app.statusItem == nil && app.result != nil })
        check(lifecycle.previewOpen && !terminated, "Warning preserved preview")

        // Critical pressure cancels generation, removes the icon, and permits reloading.
        app.startEdit(.rewrite)
        pump(until: { app.result != nil && app.statusItem != nil })
        control.setBlocked(true); app.startEdit(.grammar)
        pump(until: { app.statusItem?.button?.toolTip?.contains("Working") == true })
        app.releaseForMemoryPressure(critical: true)
        pump(until: { app.statusItem == nil })
        check(app.result == nil && app.status.stringValue.contains("free memory"), "Critical pressure exposes retry instead of stale output")
        control.setBlocked(false); app.startEdit(.grammar)
        pump(until: { app.result != nil && app.statusItem != nil })
        check(creations == 3, "Reload after each pressure unload")

        app.cancel()
        pump(until: { lifecycle.idleSince != nil })
        lifecycle.setMinutes(5)
        lifecycle.workerDrained(token: lifecycle.generation, now: Date().addingTimeInterval(-301))
        app.didWake()
        pump(until: { terminated })
        check(lifecycle.quitting, "Wake expires idle model and quits")
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS app menus, preview clearing, warm shortcuts, pressure cleanup, reload, and expiry after wake")

        // Quit while active must wait for cooperative cancellation and release.
        var quitFinished = false
        let quitControl = Control(); quitControl.setBlocked(true)
        let quitting = SelectionApp(model: ResidentModel { Session(quitControl) }, lifecycle: ModelLifecycle(defaults: Preferences()),
            resources: resources, capture: {
                CapturedSelection(app: .current, field: nil, window: nil,
                    identity: SelectionIdentity(pid: ProcessInfo.processInfo.processIdentifier, text: "She have ticket 4821.", range: nil))
            }, terminate: { quitFinished = true })
        quitting.makePanel(); quitting.startEdit(.grammar)
        pump(until: { quitting.statusItem?.button?.toolTip?.contains("Working") == true })
        quitting.quit()
        check(quitting.captured == nil && quitting.result == nil, "Quit clears preview immediately")
        pump(until: { quitFinished })
        quitting.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        var emptyFinished = false
        let empty = SelectionApp(lifecycle: ModelLifecycle(defaults: Preferences()), resources: resources,
            capture: { throw EditingFailure("No selection") }, terminate: { emptyFinished = true })
        empty.makePanel(); empty.startEdit(.grammar); empty.cancel()
        pump(until: { emptyFinished })
        empty.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS Quit during generation and immediate exit when no model loaded")
    }
}
