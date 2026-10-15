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

final class SelectionApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: PreviewPanel!
    private let body = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 240))
    private let scroll = NSScrollView()
    private let formatPicker = NSSegmentedControl(labels: ["Preview", "Markdown"], trackingMode: .selectOne, target: nil, action: nil)
    private var displayText = ""
    private let context = NSTextField(labelWithString: "Selected text")
    private let status = NSTextField(wrappingLabelWithString: "Reading selected text…")
    private let spinner = NSProgressIndicator()
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let tonePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let worker = DispatchQueue(label: "grammarly.selection.inference", qos: .userInitiated)
    private var captured: CapturedSelection?
    private var result: String?
    private var job: EditingJob?
    private var inference: EmbeddedInferenceSession?
    private var closing = false
    private var readyToTerminate = false
    private var generation = 0
    private var action: EditingAction = .grammar
    private var demo = false
    private var lockDescriptor: Int32 = -1
    private var resources: URL { Bundle.main.resourceURL! }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        demo = arguments.contains("--demo") || arguments.contains("--render-preview")
        if let index = arguments.firstIndex(of: "--action"), index + 1 < arguments.count {
            guard let requested = EditingAction(rawValue: arguments[index + 1]) else { NSApp.terminate(nil); return }
            action = requested
        }
        let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("grammarly-selection-preview.lock").path
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.grammarly.selection.show"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleRepeatedCommand), name: Notification.Name("local.grammarly.selection.show"), object: nil)
        makePanel()
        if demo {
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
            // Capture before showing any window so the source app keeps focus.
            readSelectionAndEdit()
        }
    }

    private func makePanel() {
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
        let title = NSTextField(labelWithString: action.title)
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
        guard panel != nil, !closing else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(body)
    }

    @objc private func handleRepeatedCommand() {
        guard !closing else { return }
        // After granting Accessibility, running the command again should retry
        // selection capture rather than bring back the old permission message.
        if captured == nil && !demo && AXIsProcessTrusted() {
            panel.orderOut(nil)
            readSelectionAndEdit()
        } else { showExisting() }
    }

    private func readSelectionAndEdit() {
        do {
            guard AXIsProcessTrusted() else {
                // macOS owns this consent; installation never grants it silently.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                throw EditingFailure("Allow GrammarNazi in System Settings → Privacy & Security → Accessibility, then return to your app and run the command again.")
            }
            captured = try CapturedSelection.capture()
            context.stringValue = "Selected text in \(captured!.app.localizedName ?? "your app")"
            displayText = captured!.text
            updateBody()
            showExisting()
            generate()
        } catch { showError(error); showExisting() }
    }

    private func generate() {
        guard let captured, !demo, !closing else { return }
        job?.cancel()
        generation += 1
        let current = generation
        let task = EditingJob()
        job = task; result = nil
        replaceButton.isEnabled = false; copyButton.isEnabled = false; retryButton.isHidden = true
        spinner.isHidden = false; spinner.startAnimation(nil)
        status.textColor = .secondaryLabelColor; status.stringValue = action.progress
        let resources = self.resources
        let tone = RewriteTone.allCases[tonePicker.indexOfSelectedItem]
        let action = self.action
        worker.async { [self] in
            do {
                struct Configuration: Decodable { let modelPath: String }
                let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: resources.appendingPathComponent("configuration.json")))
                let rules = try JSONDecoder().decode(EditingRules.self, from: Data(contentsOf: resources.appendingPathComponent("editing-rules.json")))
                let result: String
                if EditingRules.requiresInference(captured.text) {
                    let request = try rules.request(text: captured.text, action: action, tone: tone)
                    if inference == nil { inference = try EmbeddedInferenceSession() }
                    let response = try task.run(session: inference!, model: URL(fileURLWithPath: configuration.modelPath), request: request)
                    result = try EditingRules.completion(response, original: captured.text)
                } else { result = captured.text }
                DispatchQueue.main.async {
                    guard current == self.generation, !self.closing else { return }
                    self.job = nil; self.result = result; self.displayText = result; self.updateBody()
                    self.spinner.stopAnimation(nil); self.spinner.isHidden = true
                    self.status.stringValue = result == captured.text ? "Your text already looks correct." : "Review the result. Return replaces; ⌘C copies; Esc cancels."
                    self.replaceButton.isEnabled = true; self.copyButton.isEnabled = true
                }
            } catch {
                DispatchQueue.main.async {
                    guard current == self.generation, !self.closing else { return }
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

    @objc private func cancel() {
        guard !closing else { return }
        closing = true; generation += 1
        job?.cancel(); panel?.orderOut(nil)
        // Drain the worker before freeing model resources and exiting. The UI never waits.
        worker.async { [self] in
            inference = nil
            DispatchQueue.main.async { self.readyToTerminate = true; NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        cancel()
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        job?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }
}

@main struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = SelectionApp()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
