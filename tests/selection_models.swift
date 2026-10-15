import Foundation

@main struct SelectionModelTests {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        struct Configuration: Decodable { let modelPath: String }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: resources.appendingPathComponent("configuration.json")))
        let rules = try JSONDecoder().decode(EditingRules.self, from: Data(contentsOf: resources.appendingPathComponent("editing-rules.json")))
        let cases: [(EditingAction, String)] = [(.grammar, "She dont have invoice 4821, but she have the report."), (.rewrite, "I was wondering if maybe you could send me an update about ticket 4821 when you have time.")]
        for (action, text) in cases {
            let request = try rules.request(text: text, action: action, tone: .professional)
            let start = Date()
            let data = try EditingJob().run(resources: resources, model: URL(fileURLWithPath: config.modelPath), request: request)
            let result = try EditingRules.completion(data, original: text)
            guard result.contains("4821"), !result.isEmpty else { fatalError("The model lost the ticket/invoice number") }
            if action == .grammar {
                guard result.contains("doesn't") || result.contains("does not") else { fatalError("The grammar correction was not applied") }
                guard result.contains("has the report") else { fatalError("Verb agreement was not corrected") }
            }
            print("PASS native \(action.rawValue) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s): \(result)")
        }
    }
}
