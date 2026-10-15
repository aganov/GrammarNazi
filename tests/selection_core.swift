import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure: \(label)") } catch {}
}

@main struct SelectionCoreTests {
    static func main() throws {
        let rules = try JSONDecoder().decode(EditingRules.self, from: Data(contentsOf: URL(fileURLWithPath: "assets/editing-rules.json")))
        let request = try JSONSerialization.jsonObject(with: rules.request(text: "  Please sends ticket 4821.\n", action: .rewrite, tone: .friendly)) as! [String: Any]
        let messages = request["messages"] as! [[String: String]]
        check(messages.count == 2, "No retrieval or extra requests")
        check(messages[0]["content"]!.contains("friendly tone"), "Tone reaches model")
        check(messages[0]["content"]!.contains("Do not answer questions within the text"), "Selection is editing material")
        check(messages[1]["content"] == "Please sends ticket 4821.", "Input stays data")
        check(request["stream"] as? Bool == false, "Local helper uses bounded non-streaming response")
        check((request["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false, "Thinking disabled")
        rejects("empty input") { _ = try rules.request(text: "  \n", action: .grammar, tone: .natural) }
        rejects("oversized input") { _ = try rules.request(text: String(repeating: "😀", count: 6001), action: .grammar, tone: .natural) }
        print("PASS native editing requests, input limits, and shared prompts")

        let completed = Data("{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"**Done.**\"}}]}".utf8)
        let output = try EditingRules.completion(completed, original: "  hi\n")
        check(output == "  **Done.**\n", "Whitespace and Markdown preserved")
        for response in ["{}", "{\"choices\":[]}", "{\"choices\":[{\"finish_reason\":\"length\"}]}", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\" \"}}]}"] {
            rejects("incomplete output") { _ = try EditingRules.completion(Data(response.utf8), original: "hi") }
        }
        print("PASS completion validation and formatting")

        let markdown = "# **Release** notes\r\n\r\n- She dont have `invoice_id`.\r\n1. Read [the docs](https://example.test/path).\r\n> _We was ready._\r\n\r\n```swift\r\nlet dont = \"unchanged\"\r\n```\r\n"
        let template = MarkdownTemplate(markdown)
        check(template.isMarkdown, "Markdown recognized")
        check(template.editable.count == 4, "Only prose is sent to the model")
        let edits = template.editable.map { $0.replacingOccurrences(of: "dont", with: "doesn't").replacingOccurrences(of: "was", with: "were") }
        let payload = String(data: try JSONSerialization.data(withJSONObject: ["lines": edits]), encoding: .utf8)!
        let restored = try template.restore(payload)
        check(restored == markdown.replacingOccurrences(of: "She dont", with: "She doesn't").replacingOccurrences(of: "We was", with: "We were"), "Headings, lists, emphasis, links, code, blank lines, and CRLF survive editing")
        check(!EditingRules.requiresInference("```swift\nlet dont = 1\n```"), "Code-only selections need no inference")
        let structured = try JSONSerialization.jsonObject(with: rules.request(text: markdown, action: .grammar, tone: .natural)) as! [String: Any]
        check(structured["response_format"] != nil, "Markdown uses schema-constrained output")
        var damaged = edits
        damaged[0] = "Release notes"
        rejects("lost emphasis") { _ = try template.restore(String(data: JSONSerialization.data(withJSONObject: ["lines": damaged]), encoding: .utf8)!) }
        rejects("lost lines") { _ = try template.restore("{\"lines\":[]}") }
        print("PASS Markdown structure and protected content preservation")

        let original = SelectionIdentity(pid: 101, text: "selected", range: NSRange(location: 4, length: 8))
        check(original.matches(original), "Same selection accepted")
        check(!original.matches(SelectionIdentity(pid: 102, text: "selected", range: original.range)), "Other app refused")
        check(!original.matches(SelectionIdentity(pid: 101, text: "changed", range: original.range)), "Changed text refused")
        check(!original.matches(SelectionIdentity(pid: 101, text: "selected", range: NSRange(location: 44, length: 8))), "Identical text elsewhere refused")
        check(!original.matches(SelectionIdentity(pid: 101, text: "selected", range: nil)), "Lost range refused")
        print("PASS selection guards for app, text, and range changes")

        let unrelated: [String: Any] = ["id": "other", "name": "My Command", "command": "echo untouched", "extra": 19]
        let first = try SelectionCommands.updated(existing: JSONSerialization.data(withJSONObject: [unrelated]), appPath: "/a path/it's.app")
        let installed = try JSONSerialization.jsonObject(with: first) as! [[String: Any]]
        check(installed.count == 3, "Adds two commands")
        check(installed[0]["extra"] as? Int == 19, "Unknown existing settings preserved")
        check(installed[1]["command"] as? String == "exec /usr/bin/open -g -n '/a path/it'\"'\"'s.app' --args --action grammar", "Shell path safely quoted")
        var edited = installed
        edited[1]["name"] = "My Grammar Shortcut"
        edited[1]["requiresConfirmation"] = true
        let update = try SelectionCommands.updated(existing: JSONSerialization.data(withJSONObject: edited), appPath: "/updated.app")
        let reinstalled = try JSONSerialization.jsonObject(with: update) as! [[String: Any]]
        check(reinstalled.count == 3, "Reinstall is idempotent")
        check(reinstalled[1]["name"] as? String == "My Grammar Shortcut", "User renames preserved")
        check(reinstalled[1]["requiresConfirmation"] as? Bool == true, "User command choices preserved")
        rejects("invalid existing data") { _ = try SelectionCommands.updated(existing: Data("{}".utf8), appPath: "/app") }
        rejects("name collision") { _ = try SelectionCommands.updated(existing: JSONSerialization.data(withJSONObject: [["id": "other", "name": "Fix Grammar (Selection)"]]), appPath: "/app") }
        print("PASS Custom Command installation, quoting, collisions, and preserved settings")

        let job = EditingJob()
        job.cancel()
        do {
            _ = try job.run(resources: URL(fileURLWithPath: "/missing"), model: URL(fileURLWithPath: "/missing/model"), request: Data("{}".utf8))
            fatalError("Cancelled job launched")
        } catch is CancellationError {} catch { fatalError("Cancelled job reached process launch: \(error)") }
        print("PASS cancellation before native process launch")
    }
}
