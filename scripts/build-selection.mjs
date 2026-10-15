import { execFileSync } from "node:child_process";
import { mkdir, cp, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";

if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("Build on an Apple Silicon Mac.");
const app = "dist/Grammarly Local.app";
const resources = join(app, "Contents/Resources");
await mkdir(join(app, "Contents/MacOS"), { recursive: true });
await mkdir(resources, { recursive: true });
await mkdir("vendor/swift-cache", { recursive: true });
const flags = ["-O", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", resolve("vendor/swift-cache")];
execFileSync("/usr/bin/xcrun", ["swiftc", ...flags, "native/selection/Editing.swift", "native/selection/Selection.swift", "native/selection/SelectionApp.swift", "-o", join(app, "Contents/MacOS/GrammarlyLocal")], { stdio: "inherit" });
execFileSync("/usr/bin/xcrun", ["swiftc", ...flags, "native/selection/Editing.swift", "native/selection/CustomCommands.swift", "native/selection/InstallCommands.swift", "-o", "dist/install-commands"], { stdio: "inherit" });
await cp("dist/assets/grammarly-helper", join(resources, "grammarly-helper"));
await cp("dist/assets/llama", join(resources, "llama"), { recursive: true, dereference: true });
await cp("assets/editing-rules.json", join(resources, "editing-rules.json"));
await cp("assets/Acknowledgements.txt", join(resources, "Acknowledgements.txt"));
await cp("LICENSE", join(resources, "LICENSE"));
await writeFile(join(resources, "configuration.json"), JSON.stringify({ modelPath: resolve("models/Qwen3.5-4B-Q4_K_M.gguf") }, null, 2) + "\n");
await writeFile(join(app, "Contents/Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.grammarly.selection</string>
<key>CFBundleName</key><string>Grammarly Local</string>
<key>CFBundleExecutable</key><string>GrammarlyLocal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>Read your selected text and replace it only when you choose Replace.</string>
</dict></plist>\n`);
execFileSync("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app], { stdio: "inherit" });
const quote = (s) => "'" + s.replaceAll("'", "'\"'\"'") + "'";
const command = (action) => `exec /usr/bin/open -g -n ${quote(resolve(app))} --args --action ${action}`;
await writeFile("dist/custom-commands.txt", `Tinycast 0.9.7-sequoia → Settings → Custom Commands\n\nFix Grammar (Selection)\n${command("grammar")}\n\nRewrite (Selection)\n${command("rewrite")}\n\nLoad shell environment: off\nNeeds confirmation: off\nShow confirmation: off\n\nGrant Grammarly Local Accessibility permission, then select text in your app and run a command.\n`);
console.log(`Built ${app} for macOS 15. Custom Commands are listed in dist/custom-commands.txt.`);
