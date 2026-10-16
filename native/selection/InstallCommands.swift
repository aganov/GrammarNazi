import Foundation
import AppKit

@main struct InstallCommands {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Install", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: install-commands APP_PATH"]) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/MacOS/GrammarNazi").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw NSError(domain: "Install", code: 2, userInfo: [NSLocalizedDescriptionKey: "Build the native app first."]) }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinycast.app") != nil else {
            print("Tinycast is not installed; use the Raycast Script Commands or the manual launch commands.")
            return
        }
        let defaults = UserDefaults(suiteName: "com.tinycast.app")!
        let commands = try SelectionCommands.updated(existing: defaults.data(forKey: "customCommands"), appPath: CommandLine.arguments[1])
        defaults.set(commands, forKey: "customCommands")
        defaults.set(true, forKey: "customCommandsEnabled")
        defaults.set(true, forKey: "customCommandsShowInLauncher")
        defaults.synchronize()
        print("Installed Fix Grammar (Selection) and Rewrite (Selection). Restart Tinycast to load them.")
    }
}
