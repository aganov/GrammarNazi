import { execFileSync } from "node:child_process";
import { mkdir, cp, writeFile, access, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { buildInference } from "./inference-build.mjs";
import { tmpdir } from "node:os";

if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("Build on an Apple Silicon Mac.");
// Build only the native app; old extension bundles must not remain importable.
const inferenceFlags = await buildInference();
await access("models/Qwen3.5-4B-Q4_K_M.gguf").catch(() => { throw new Error("Run npm run setup before building."); });
await rm("dist", { recursive: true, force: true });
const app = "dist/GrammarNazi.app";
const resources = join(app, "Contents/Resources");
await mkdir(join(app, "Contents/MacOS"), { recursive: true });
await mkdir(resources, { recursive: true });
// Keep the module cache at a stable path when the project directory is renamed.
const swiftCache = join(tmpdir(), "grammarnazi-swift-cache");
await mkdir(swiftCache, { recursive: true });
const flags = ["-O", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", swiftCache];
execFileSync("/usr/bin/xcrun", ["swiftc", ...flags, ...inferenceFlags, "native/selection/Inference.swift", "native/selection/Markdown.swift", "native/selection/Editing.swift", "native/selection/MarkdownPreview.swift", "native/selection/Selection.swift", "native/selection/SelectionApp.swift", "-o", join(app, "Contents/MacOS/GrammarNazi")], { stdio: "inherit" });
execFileSync("/usr/bin/xcrun", ["swiftc", ...flags, "native/selection/Markdown.swift", "native/selection/Editing.swift", "native/selection/CustomCommands.swift", "native/selection/InstallCommands.swift", "-o", "dist/install-commands"], { stdio: "inherit" });
await cp("vendor/llama.cpp-b11461/LICENSE", join(resources, "llama-LICENSE"));
await cp("assets/editing-rules.json", join(resources, "editing-rules.json"));
await cp("assets/Acknowledgements.txt", join(resources, "Acknowledgements.txt"));
await cp("LICENSE", join(resources, "LICENSE"));
await writeFile(join(resources, "configuration.json"), JSON.stringify({ modelPath: resolve("models/Qwen3.5-4B-Q4_K_M.gguf") }, null, 2) + "\n");
await writeFile(join(app, "Contents/Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.grammarly.selection</string>
<key>CFBundleName</key><string>GrammarNazi</string>
<key>CFBundleExecutable</key><string>GrammarNazi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>Read your selected text and replace it only when you choose Replace.</string>
</dict></plist>\n`);
execFileSync("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app], { stdio: "inherit" });
const quote = (s) => "'" + s.replaceAll("'", "'\"'\"'") + "'";
const command = (action) => `exec /usr/bin/open -g -n ${quote(resolve(app))} --args --action ${action}`;
await writeFile("dist/custom-commands.txt", `Tinycast 0.9.7-sequoia → Settings → Custom Commands\n\nFix Grammar (Selection)\n${command("grammar")}\n\nRewrite (Selection)\n${command("rewrite")}\n\nLoad shell environment: off\nNeeds confirmation: off\nShow confirmation: off\n\nGrant GrammarNazi Accessibility permission, then select text in your app and run a command.\n`);
console.log(`Built ${app} for macOS 15. Custom Commands are listed in dist/custom-commands.txt.`);
