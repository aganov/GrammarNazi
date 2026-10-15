import Foundation

private final class CancellationLimit {
    private let lock = NSLock()
    private var probes = 0
    private let limit: Int
    init(_ limit: Int) { self.limit = limit }
    func check() -> Bool {
        lock.lock(); defer { lock.unlock() }
        probes += 1
        return probes > limit
    }
}

@main struct SelectionModelTests {
    static func main() throws {
        setbuf(stdout, nil)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        struct Configuration: Decodable { let modelPath: String }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: resources.appendingPathComponent("configuration.json")))
        let rules = try JSONDecoder().decode(EditingRules.self, from: Data(contentsOf: resources.appendingPathComponent("editing-rules.json")))
        let markdown = "# **Release** notes\n\n- She dont have `invoice_id`.\n1. We was ready for ticket **4821**.\n\n```swift\nlet dont = \"unchanged\"\n```\n"
        let cases: [(EditingAction, String)] = [(.grammar, "She dont have invoice 4821, but she have the report."), (.rewrite, "I was wondering if maybe you could send me an update about ticket 4821 when you have time."), (.grammar, markdown), (.rewrite, markdown)]
        weak var releasedSession: EmbeddedInferenceSession?
        do {
            let session = try EmbeddedInferenceSession()
            releasedSession = session
            let model = URL(fileURLWithPath: config.modelPath)
            let baseline = try rules.request(text: "She dont have ticket 4821.", action: .grammar, tone: .natural)
            let loading = CancellationLimit(5)
            do {
                _ = try session.run(model: model, request: baseline, isCancelled: loading.check)
                fatalError("Loading was not cancelled")
            } catch is CancellationError {}
            guard session.modelLoadCount == 0 else { fatalError("Cancelled load counted as successful") }
            print("PASS cancellation during real model loading")
            for (action, text) in cases {
                let request = try rules.request(text: text, action: action, tone: .professional)
                let start = Date()
                let data = try EditingJob().run(session: session, model: URL(fileURLWithPath: config.modelPath), request: request)
                let result = try EditingRules.completion(data, original: text)
                guard result.contains("4821"), !result.isEmpty else { fatalError("The model lost the ticket/invoice number") }
                if text == markdown {
                    guard result.hasPrefix("# **Release** notes\n\n- "), result.contains("\n1. "), result.contains("**4821**"), result.contains("`invoice_id`"), result.hasSuffix("```swift\nlet dont = \"unchanged\"\n```\n") else { fatalError("Markdown formatting changed") }
                    guard !result.contains("GNKEEP") else { fatalError("Internal markers leaked into output") }
                } else if action == .grammar {
                    guard result.contains("doesn't") || result.contains("does not") else { fatalError("The grammar correction was not applied") }
                    guard result.contains("has the report") else { fatalError("Verb agreement was not corrected") }
                }
                guard session.modelLoadCount == 1 else { fatalError("Model weights were reloaded") }
                guard !result.contains("<think>"), !result.contains("</think>") else { fatalError("Thinking leaked") }
                print("PASS native \(action.rawValue) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s): \(result)")
            }
            let generating = CancellationLimit(15)
            do {
                _ = try session.run(model: model, request: baseline, isCancelled: generating.check)
                fatalError("Generation was not cancelled")
            } catch is CancellationError {}
            _ = try EditingRules.completion(EditingJob().run(session: session, model: model, request: baseline), original: "She dont have ticket 4821.")
            guard session.modelLoadCount == 1 else { fatalError("Cancellation discarded reusable weights") }
            print("PASS real inference cancellation and retry with cached weights")
            var short = try JSONSerialization.jsonObject(with: baseline) as! [String: Any]
            short["max_tokens"] = 1
            let truncated = try session.run(model: model, request: JSONSerialization.data(withJSONObject: short), isCancelled: { false })
            do {
                _ = try EditingRules.completion(truncated, original: "She dont have ticket 4821.")
                fatalError("Truncated output accepted")
            } catch {}
            print("PASS real output-limit rejection")
        }
        guard releasedSession == nil else { fatalError("Closed preview retained native session") }
        print("PASS native session destruction after model use")
    }
}
