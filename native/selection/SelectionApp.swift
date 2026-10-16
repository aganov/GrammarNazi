import AppKit
import ApplicationServices
import Darwin

final class PreviewPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onReplace: (() -> Void)?
    var onCopy: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onCancel?(); return true }
        if event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { onReplace?(); return true }
        if event.charactersIgnoringModifiers == "c", event.modifierFlags.contains(.command) { onCopy?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class SelectionApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var panel: PreviewPanel!
    private let body = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 240))
    private let scroll = NSScrollView()
    private let formatPicker = NSSegmentedControl(labels: ["Preview", "Markdown"], trackingMode: .selectOne, target: nil, action: nil)
    private var displayText = ""
    private let context = NSTextField(labelWithString: "Selected text")
    let title = NSTextField(labelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "Reading selected text…")
    private let spinner = NSProgressIndicator()
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let tonePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let worker = DispatchQueue(label: "grammarnazi.selection.inference", qos: .userInitiated)
    private(set) var captured: CapturedSelection?
    private(set) var result: String?
    private var job: EditingJob?
    private let model: ResidentModel
    private let lifecycle: ModelLifecycle
    private let captureSelection: () throws -> CapturedSelection
    private let resourceDirectory: URL?
    private let terminate: () -> Void
    private var router: CommandRouter?
    private var idleTimer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var capturing = false
    private var pendingAction: EditingAction?
    private var modelLoaded = false
    private var phase: ModelPhase?
    private(set) var statusItem: NSStatusItem?
    private let modelMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let countdownMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var previewMenuItem: NSMenuItem?
    private var timeoutItems: [NSMenuItem] = []
    private var readyToTerminate = false
    private var action: EditingAction = .grammar
    private var demo = false
    private var resources: URL { resourceDirectory ?? Bundle.main.resourceURL! }

    init(model: ResidentModel = ResidentModel { try EmbeddedInferenceSession() }, lifecycle: ModelLifecycle = ModelLifecycle(),
         resources: URL? = nil, capture: (() throws -> CapturedSelection)? = nil,
         terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.model = model; self.lifecycle = lifecycle; self.resourceDirectory = resources; self.terminate = terminate
        self.captureSelection = capture ?? {
            guard AXIsProcessTrusted() else {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                throw EditingFailure("Allow GrammarNazi in System Settings → Privacy & Security → Accessibility, then return to your app and run the command again.")
            }
            return try CapturedSelection.capture()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        demo = arguments.contains("--demo") || arguments.contains("--render-preview")
        if let index = arguments.firstIndex(of: "--action"), index + 1 < arguments.count {
            guard let requested = EditingAction(rawValue: arguments[index + 1]) else { NSApp.terminate(nil); return }
            action = requested
        }
        if demo {
            makePanel()
            lifecycle.openPreview()
            context.stringValue = "Selected text in Slack · Demo"
            let fixture = arguments.firstIndex(of: "--fixture").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            displayText = fixture.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "Could you send me an update about ticket 4821 when you have a moment?"
            result = displayText
            if arguments.contains("--source-preview") { formatPicker.selectedSegment = 1 }
            updateBody()
            status.stringValue = "Review your rewrite, then replace the selection or copy the result."
            spinner.stopAnimation(nil); spinner.isHidden = true
            copyButton.isEnabled = true
            showExisting()
            if let index = arguments.firstIndex(of: "--render-preview"), index + 1 < arguments.count {
                let output = arguments[index + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, let content = self.panel.contentView,
                          let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { NSApp.terminate(nil); return }
                    content.layoutSubtreeIfNeeded()
                    self.body.layoutManager?.ensureLayout(for: self.body.textContainer!)
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: output)) }
                    let container = self.body.textContainer!
                    let used = self.body.layoutManager!.usedRect(for: container)
                    let report: [String: Any] = ["textWidth": used.width, "containerWidth": container.size.width, "documentHeight": self.body.frame.height, "viewportHeight": self.scroll.contentSize.height, "horizontalScroller": self.scroll.hasHorizontalScroller, "text": self.body.string]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: output + ".json")) }
                    self.cancel()
                }
            }
        } else {
            let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("grammarnazi-selection-preview.lock").path
            router = CommandRouter(action: action, lockPath: lockPath)
            router!.start(onOwner: { [weak self] in
                guard let self else { return }
                self.makePanel(); self.observeMemoryAndWake()
                self.startEdit(self.action)
            }, onRequest: { [weak self] action in self?.startEdit(action) }, onForwarded: { [weak self] in
                self?.readyToTerminate = true; NSApp.terminate(nil)
            }, onFailure: { [weak self] message in
                let alert = NSAlert(); alert.messageText = "GrammarNazi could not start"; alert.informativeText = message
                alert.runModal()
                self?.readyToTerminate = true; NSApp.terminate(nil)
            })
        }
    }

    func makePanel() {
        panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentMinSize = NSSize(width: 520, height: 400)
        panel.title = "GrammarNazi"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onReplace = { [weak self] in if self?.replaceButton.isEnabled == true { self?.replace() } }
        panel.onCopy = { [weak self] in if self?.copyButton.isEnabled == true { self?.copyResult() } }

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = content
        title.stringValue = action.title
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        context.font = .systemFont(ofSize: 12)
        context.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, context])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 4
        context.lineBreakMode = .byTruncatingTail
        tonePicker.addItems(withTitles: RewriteTone.allCases.map(\.title))
        tonePicker.selectItem(withTitle: UserDefaults.standard.string(forKey: "rewriteTone").flatMap(RewriteTone.init(rawValue:))?.title ?? "Natural")
        tonePicker.target = self; tonePicker.action = #selector(changeTone)
        tonePicker.toolTip = "Rewrite tone"
        tonePicker.isHidden = action != .rewrite
        tonePicker.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [heading, NSView(), tonePicker])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12

        body.isEditable = false; body.isSelectable = true
        body.font = .systemFont(ofSize: 15)
        body.textColor = .labelColor
        body.drawsBackground = false
        body.textContainerInset = NSSize(width: 2, height: 8)
        body.isVerticallyResizable = true; body.isHorizontallyResizable = false
        body.minSize = .zero
        body.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        body.textContainer?.lineBreakMode = .byWordWrapping
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.documentView = body
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        formatPicker.selectedSegment = 0
        formatPicker.target = self; formatPicker.action = #selector(changeFormat)

        spinner.style = .spinning; spinner.controlSize = .small
        spinner.startAnimation(nil)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        let feedback = NSStackView(views: [spinner, status])
        feedback.orientation = .horizontal; feedback.alignment = .centerY; feedback.spacing = 8

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        retryButton.target = self; retryButton.action = #selector(retry)
        retryButton.isHidden = true
        copyButton.target = self; copyButton.action = #selector(copyResult)
        copyButton.isEnabled = false
        replaceButton.target = self; replaceButton.action = #selector(replace)
        replaceButton.keyEquivalent = "\r"; replaceButton.isEnabled = false
        for button in [cancel, retryButton, copyButton, replaceButton] { button.bezelStyle = .rounded }
        let footer = NSStackView(views: [cancel, retryButton, NSView(), copyButton, replaceButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8
        let stack = NSStackView(views: [header, formatPicker, scroll, feedback, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.center()
    }

    @objc private func changeFormat() { updateBody() }

    private func updateBody() {
        panel.contentView?.layoutSubtreeIfNeeded()
        body.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(1, scroll.contentSize.height)))
        body.textStorage?.setAttributedString(MarkdownPreview.render(displayText, raw: formatPicker.selectedSegment == 1))
        if let container = body.textContainer, let layout = body.layoutManager {
            layout.ensureLayout(for: container)
            let height = layout.usedRect(for: container).height + body.textContainerInset.height * 2
            body.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, height)))
        }
        body.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    @objc private func showExisting() {
        guard panel != nil, lifecycle.previewOpen, !lifecycle.quitting else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(body)
    }

    func startEdit(_ requested: EditingAction) {
        guard !lifecycle.quitting else { return }
        idleTimer?.invalidate(); idleTimer = nil
        job?.cancel(); job = nil
        lifecycle.openPreview()
        panel.orderOut(nil)
        clearSelection()
        action = requested; title.stringValue = action.title
        tonePicker.isHidden = action != .rewrite
        formatPicker.selectedSegment = 0
        // Selection.capture pumps the run loop while waiting for launcher focus.
        // Coalesce reentrant commands and never publish an older capture.
        if capturing { pendingAction = requested; return }
        readSelectionAndEdit()
    }

    private func readSelectionAndEdit() {
        let token = lifecycle.generation
        capturing = true
        defer {
            capturing = false
            if let requested = pendingAction {
                pendingAction = nil
                let pendingToken = lifecycle.generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lifecycle.accepts(pendingToken) else { return }
                    self.startEdit(requested)
                }
            }
        }
        do {
            let selection = try captureSelection()
            guard lifecycle.accepts(token) else { return }
            captured = selection
            context.stringValue = "Selected text in \(captured!.app.localizedName ?? "your app")"
            displayText = captured!.text
            updateBody()
            showExisting()
            generate()
        } catch {
            guard lifecycle.accepts(token) else { return }
            showError(error); showExisting()
        }
    }

    private func generate() {
        guard let captured, !demo, lifecycle.previewOpen, !lifecycle.quitting else { return }
        job?.cancel()
        let current = lifecycle.nextGeneration()
        let task = EditingJob()
        job = task; result = nil
        replaceButton.isEnabled = false; copyButton.isEnabled = false; retryButton.isHidden = true
        spinner.isHidden = false; spinner.startAnimation(nil)
        status.textColor = .secondaryLabelColor; status.stringValue = action.progress
        let resources = self.resources
        let tone = RewriteTone.allCases[tonePicker.indexOfSelectedItem]
        let action = self.action
        worker.async { [self] in
            defer {
                let loaded = model.isModelLoaded
                DispatchQueue.main.async {
                    guard !self.lifecycle.quitting else { return }
                    self.modelLoaded = loaded; self.phase = loaded ? .ready : nil
                    self.refreshStatusItem()
                }
            }
            do {
                struct Configuration: Decodable { let modelPath: String }
                let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: resources.appendingPathComponent("configuration.json")))
                let rules = try JSONDecoder().decode(EditingRules.self, from: Data(contentsOf: resources.appendingPathComponent("editing-rules.json")))
                let result: String
                if EditingRules.requiresInference(captured.text) {
                    let request = try rules.request(text: captured.text, action: action, tone: tone)
                    model.onPhase = { [weak self] phase in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.lifecycle.quitting else { return }
                            self.phase = phase; self.refreshStatusItem()
                        }
                    }
                    let response = try task.run(session: model, model: URL(fileURLWithPath: configuration.modelPath), request: request)
                    result = try EditingRules.completion(response, original: captured.text)
                } else { result = captured.text }
                DispatchQueue.main.async {
                    guard self.lifecycle.accepts(current) else { return }
                    self.job = nil; self.result = result; self.displayText = result; self.updateBody()
                    self.spinner.stopAnimation(nil); self.spinner.isHidden = true
                    self.status.stringValue = result == captured.text ? "Your text already looks correct." : "Review the result. Return replaces; ⌘C copies; Esc cancels."
                    self.replaceButton.isEnabled = true; self.copyButton.isEnabled = true
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.lifecycle.accepts(current) else { return }
                    self.job = nil
                    self.showError(error)
                }
            }
        }
    }

    private func showError(_ error: Error) {
        spinner.stopAnimation(nil); spinner.isHidden = true
        status.stringValue = error.localizedDescription; status.textColor = .systemOrange
        retryButton.title = AXIsProcessTrusted() ? "Try Again" : "Accessibility Settings"
        retryButton.isHidden = false
    }

    @objc private func changeTone() {
        let tone = RewriteTone.allCases[tonePicker.indexOfSelectedItem]
        UserDefaults.standard.set(tone.rawValue, forKey: "rewriteTone")
        generate()
    }

    @objc private func retry() {
        if !AXIsProcessTrusted() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            cancel() // The next command starts with the newly granted permission.
        } else if captured == nil { panel.orderOut(nil); readSelectionAndEdit() }
        else { generate() }
    }

    @objc private func copyResult() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        cancel()
    }

    @objc private func replace() {
        guard let result, let captured, !demo else { return }
        panel.orderOut(nil)
        do { try captured.replace(with: result); cancel() }
        catch { showError(error); showExisting() }
    }

    @objc func cancel() {
        guard !lifecycle.quitting else { return }
        let token = lifecycle.closePreview()
        job?.cancel(); job = nil; pendingAction = nil
        panel?.orderOut(nil); clearSelection()
        // The idle interval begins only after cancellation and worker cleanup finish.
        worker.async { [self] in
            let loaded = model.isModelLoaded
            DispatchQueue.main.async {
                guard token == self.lifecycle.generation, !self.lifecycle.previewOpen, !self.lifecycle.quitting else { return }
                guard loaded, !self.demo else { self.quit(); return }
                self.modelLoaded = true; self.phase = .ready
                self.lifecycle.workerDrained(token: token, now: Date())
                self.armIdleTimer(); self.refreshStatusItem()
            }
        }
    }

    private func clearSelection() {
        captured = nil; result = nil; displayText = ""
        body.textStorage?.setAttributedString(NSAttributedString(string: ""))
        context.stringValue = "Selected text"
        status.stringValue = "Reading selected text…"; status.textColor = .secondaryLabelColor
        copyButton.isEnabled = false; replaceButton.isEnabled = false; retryButton.isHidden = true
        spinner.stopAnimation(nil); spinner.isHidden = true
    }

    @objc func quit() {
        guard !lifecycle.quitting else { return }
        lifecycle.quit(); router?.stopAccepting()
        idleTimer?.invalidate(); idleTimer = nil
        pressureSource?.cancel(); pressureSource = nil
        pendingAction = nil
        job?.cancel(); job = nil; panel?.orderOut(nil); clearSelection()
        // Keep the lock until process exit so a new launch retries during shutdown.
        worker.async { [self] in
            model.unload()
            DispatchQueue.main.async { self.readyToTerminate = true; self.terminate() }
        }
    }

    private func armIdleTimer() {
        idleTimer?.invalidate(); idleTimer = nil
        guard !lifecycle.quitting else { return }
        if lifecycle.expired(at: Date()) { quit(); return }
        guard let deadline = lifecycle.deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.armIdleTimer()
        }
        idleTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func observeMemoryAndWake() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            self.releaseForMemoryPressure(critical: source.data.contains(.critical))
        }
        pressureSource = source; source.resume()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func didWake() { armIdleTimer(); refreshStatusItem() }

    func releaseForMemoryPressure(critical: Bool) {
        guard !demo, !lifecycle.quitting else { return }
        if critical, job != nil {
            job?.cancel(); job = nil; lifecycle.nextGeneration()
            if lifecycle.previewOpen {
                showError(EditingFailure("Editing stopped to free memory. Try Again to reload the model."))
            }
        }
        // Warning waits for current work; critical cancellation is cooperative.
        // Destruction always runs behind inference on the same serial worker.
        worker.async { [self] in
            model.unload()
            DispatchQueue.main.async {
                guard !self.lifecycle.quitting else { return }
                self.modelLoaded = false; self.phase = nil; self.refreshStatusItem()
                if !self.lifecycle.previewOpen { self.quit() }
            }
        }
    }

    private func refreshStatusItem() {
        guard !demo else { return }
        guard modelLoaded || phase == .loading || phase == .working else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil; timeoutItems = []; previewMenuItem = nil
            // Items may be reused when a later request reloads the model.
            modelMenuItem.menu?.removeItem(modelMenuItem)
            countdownMenuItem.menu?.removeItem(countdownMenuItem)
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "GrammarNazi")
            image?.isTemplate = true
            item.button?.image = image
            if image == nil { item.button?.title = "GN" }
            let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
            menu.addItem(withTitle: "GrammarNazi", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(modelMenuItem); modelMenuItem.isEnabled = false
            menu.addItem(countdownMenuItem); countdownMenuItem.isEnabled = false
            menu.addItem(.separator())
            let retention = NSMenuItem(title: "Keep Model Loaded", action: nil, keyEquivalent: "")
            let options = NSMenu()
            timeoutItems = ModelLifecycle.timeoutChoices.map { minutes in
                let option = NSMenuItem(title: minutes == 0 ? "Until Quit" : "\(minutes) minutes", action: #selector(changeTimeout(_:)), keyEquivalent: "")
                option.target = self; option.tag = minutes; options.addItem(option)
                return option
            }
            retention.submenu = options; menu.addItem(retention)
            menu.addItem(.separator())
            let preview = NSMenuItem(title: "Show Preview", action: #selector(showExisting), keyEquivalent: "")
            preview.target = self; menu.addItem(preview); previewMenuItem = preview
            let quitItem = NSMenuItem(title: "Quit GrammarNazi", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self; menu.addItem(quitItem)
            item.menu = menu; statusItem = item
        }
        statusItem?.button?.toolTip = "GrammarNazi — \(phase?.rawValue ?? ModelPhase.ready.rawValue)"
        updateMenu()
    }

    private func updateMenu() {
        modelMenuItem.title = "Model: \(phase?.rawValue ?? ModelPhase.ready.rawValue)"
        countdownMenuItem.isHidden = lifecycle.idleSince == nil
        if let deadline = lifecycle.deadline {
            let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow / 60)))
            countdownMenuItem.title = "Unloads in \(remaining) \(remaining == 1 ? "minute" : "minutes")"
        } else { countdownMenuItem.title = "Stays loaded until quit" }
        previewMenuItem?.isEnabled = lifecycle.previewOpen && !lifecycle.quitting
        timeoutItems.forEach { $0.state = $0.tag == lifecycle.minutes ? .on : .off }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu() }

    @objc func changeTimeout(_ sender: NSMenuItem) {
        lifecycle.setMinutes(sender.tag)
        armIdleTimer(); updateMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        quit()
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        job?.cancel()
        idleTimer?.invalidate(); pressureSource?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        router?.stop()
    }
}

#if !RESIDENT_TESTS
@main struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = SelectionApp()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
#endif
