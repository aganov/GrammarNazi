import Foundation

enum SelectionCommands {
    static let definitions = [
        ("grammar", "Fix Grammar (Selection)", "2FCBE7A4-29C5-4FFB-A7C7-CA816584FEF0"),
        ("rewrite", "Rewrite (Selection)", "7540C2F9-765B-41EE-AB66-702A45405582")
    ]

    static func updated(existing: Data?, appPath: String) throws -> Data {
        var commands: [[String: Any]] = []
        if let existing {
            guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [[String: Any]] else {
                throw EditingFailure("Existing Tinycast Custom Commands could not be read. Nothing was changed.")
            }
            commands = decoded
        }
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        for (action, name, identifier) in definitions {
            // LaunchServices gives the app its own Accessibility identity; -g
            // leaves the source app active, and -n delivers this run's arguments.
            let command = "exec /usr/bin/open -g -n " + quote(appPath) + " --args --action " + action
            if let index = commands.firstIndex(where: { ($0["id"] as? String)?.uppercased() == identifier }) {
                commands[index]["command"] = command
            } else {
                guard !commands.contains(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() }) else {
                    throw EditingFailure("A command named \(name) already exists. Rename it before installing.")
                }
                commands.append(["id": identifier, "name": name, "command": command, "loadsShellEnvironment": false, "requiresConfirmation": false, "showsConfirmation": false])
            }
        }
        return try JSONSerialization.data(withJSONObject: commands)
    }
}
