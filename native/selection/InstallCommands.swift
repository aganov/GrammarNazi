import Foundation

@main struct InstallCommands {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw NSError(domain: "Install", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: install-commands APP_PATH BACKUP_FILE"]) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/MacOS/GrammarlyLocal").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw NSError(domain: "Install", code: 2, userInfo: [NSLocalizedDescriptionKey: "Build the native app first."]) }
        let defaults = UserDefaults(suiteName: "com.tinycast.app")!
        let original = defaults.data(forKey: "customCommands")
        let commands = try SelectionCommands.updated(existing: original, appPath: CommandLine.arguments[1])
        let backup: [String: Any] = ["customCommands": original?.base64EncodedString() ?? "", "customCommandsEnabled": defaults.object(forKey: "customCommandsEnabled") ?? NSNull(), "customCommandsShowInLauncher": defaults.object(forKey: "customCommandsShowInLauncher") ?? NSNull()]
        let backupURL = URL(fileURLWithPath: CommandLine.arguments[2])
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys]).write(to: backupURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        defaults.set(commands, forKey: "customCommands")
        defaults.set(true, forKey: "customCommandsEnabled")
        defaults.set(true, forKey: "customCommandsShowInLauncher")
        defaults.synchronize()
        print("Installed Fix Grammar (Selection) and Rewrite (Selection). Restart Tinycast to load them.")
    }
}
