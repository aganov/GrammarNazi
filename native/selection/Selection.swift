import AppKit
import ApplicationServices
import Carbon

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func selectedRange(_ element: AXUIElement?) -> NSRange? {
    guard let element, let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
    return NSRange(location: range.location, length: range.length)
}

struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ clipboard: NSPasteboard) throws {
        var total = 0
        items = try (clipboard.pasteboardItems ?? []).map { item in
            var result: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw EditingFailure("Your clipboard cannot be temporarily saved. Copy the result and paste it manually.") }
                total += data.count
                guard total <= 16 * 1024 * 1024 else { throw EditingFailure("Your clipboard is too large to temporarily save. Copy the result and paste it manually.") }
                result[type] = data
            }
            return result
        }
    }

    func restore(_ clipboard: NSPasteboard, ifUnchanged count: Int) {
        guard clipboard.changeCount == count else { return } // Never clobber a newer user copy.
        let objects = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        clipboard.clearContents()
        if !objects.isEmpty { clipboard.writeObjects(objects) }
    }
}

struct CapturedSelection {
    let app: NSRunningApplication
    let field: AXUIElement?
    let window: AXUIElement?
    let identity: SelectionIdentity
    var text: String { identity.text }

    private static func checkEnvironment() throws {
        guard AXIsProcessTrusted() else { throw EditingFailure("Allow GrammarNazi in System Settings → Privacy & Security → Accessibility, then run the command again.") }
        guard !IsSecureEventInputEnabled() else { throw EditingFailure("Text editing is unavailable while Secure Input is enabled.") }
    }

    private static func focusedField(_ app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps, including Slack, may not build their accessibility tree until asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return elementAttribute(element, kAXFocusedUIElementAttribute)
    }

    private static func checkTarget(_ app: NSRunningApplication) throws {
        try checkEnvironment()
        guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw EditingFailure("The active app changed. Return to the original selection and try again, or copy the result.")
        }
    }

    private static func postShortcut(_ key: CGKeyCode, to app: NSRunningApplication) throws {
        try checkTarget(app)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw EditingFailure("Couldn't send the keyboard shortcut to your app.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
    }

    private static func copiedSelection(in app: NSRunningApplication) throws -> String {
        try checkTarget(app)
        let clipboard = NSPasteboard.general
        let snapshot = try ClipboardSnapshot(clipboard)
        let initialCount = clipboard.changeCount
        var copiedCount: Int?
        defer { if let copiedCount { snapshot.restore(clipboard, ifUnchanged: copiedCount) } }
        try postShortcut(8, to: app) // C; never Return or a message-send shortcut.
        let deadline = Date().addingTimeInterval(0.8)
        while clipboard.changeCount == initialCount && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if clipboard.changeCount != initialCount { copiedCount = clipboard.changeCount }
            try checkTarget(app)
        }
        guard clipboard.changeCount != initialCount else {
            throw EditingFailure("No text was copied. Select text in your app and try again.")
        }
        copiedCount = clipboard.changeCount
        guard let text = clipboard.string(forType: .string), !text.isEmpty else {
            throw EditingFailure("The app didn't provide a text selection.")
        }
        return text
    }

    static func capture() throws -> CapturedSelection {
        try checkEnvironment()
        // Tinycast dismisses its palette before launching Custom Commands. Allow
        // its activation transition to complete without ever activating this app.
        let deadline = Date().addingTimeInterval(0.8)
        while NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tinycast.app" && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != "com.tinycast.app" else {
            throw EditingFailure("Select text in Slack or another app, then run this command again.")
        }
        let field = focusedField(app)
        if let field, (attribute(field, kAXRoleAttribute) as? String) == "AXSecureTextField" {
            throw EditingFailure("Password fields cannot be edited.")
        }
        let window = elementAttribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
        let range = selectedRange(field)
        let direct = field.flatMap { attribute($0, kAXSelectedTextAttribute) as? String }
        let text = try (direct?.isEmpty == false ? direct! : copiedSelection(in: app))
        try checkTarget(app)
        if let field, let current = focusedField(app), !CFEqual(field, current) {
            throw EditingFailure("The selected field changed. Select your text and try again.")
        }
        if let range, range != selectedRange(field) {
            throw EditingFailure("Your selection changed while reading it. Select your text and try again.")
        }
        return CapturedSelection(app: app, field: field, window: window, identity: SelectionIdentity(pid: app.processIdentifier, text: text, range: range))
    }

    func validateForReplacement() throws {
        try Self.checkTarget(app)
        let current = Self.focusedField(app)
        if let field {
            guard let current, CFEqual(field, current) else { throw EditingFailure("The focused field changed. Copy the result or select the original passage again.") }
        }
        if let window {
            guard let currentWindow = elementAttribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute), CFEqual(window, currentWindow) else {
                throw EditingFailure("The window changed. Copy the result or return to the original window.")
            }
        }
        let range = selectedRange(current)
        if let originalRange = identity.range, originalRange != range {
            throw EditingFailure("Your selection changed. Copy the result or select the original passage again.")
        }
        let direct = current.flatMap { attribute($0, kAXSelectedTextAttribute) as? String }
        let text = try (direct?.isEmpty == false ? direct! : Self.copiedSelection(in: app))
        guard identity.matches(SelectionIdentity(pid: app.processIdentifier, text: text, range: range)) else {
            throw EditingFailure("Your selected text changed. Copy the result or select the original passage again.")
        }
    }

    func replace(with text: String) throws {
        try validateForReplacement()
        let clipboard = NSPasteboard.general
        let snapshot = try ClipboardSnapshot(clipboard)
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
        let count = clipboard.changeCount
        defer { snapshot.restore(clipboard, ifUnchanged: count) }
        // Cmd-V preserves the source editor's normal undo behavior. The caller
        // hides the non-activating preview first; the original app retains focus.
        try Self.postShortcut(9, to: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }
}
