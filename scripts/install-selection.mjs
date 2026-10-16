import { access } from "node:fs/promises";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import { execFileSync } from "node:child_process";
import { installApp } from "./install-app.mjs";
import { writeRaycastCommands } from "./launcher-commands.mjs";

const app = join(homedir(), "Applications/GrammarNazi.app");
const scripts = join(homedir(), "Library/Application Support/GrammarNazi/raycast");
const launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
await access("dist/GrammarNazi.app/Contents/MacOS/GrammarNazi");
await access("models/Qwen3.5-4B-Q4_K_M.gguf");
await installApp("dist/GrammarNazi.app", app, (path) => {
  execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", path], { stdio: "inherit" });
});
await writeRaycastCommands(scripts, app);
execFileSync(resolve("dist/install-commands"), [app], { stdio: "inherit" });
execFileSync(launchServices, ["-f", app], { stdio: "inherit" });
console.log(`Native app: ${app}`);
console.log(`Raycast Script Commands: ${scripts}`);
console.log("Raycast: open Script Commands in Settings, choose Add Script Directory, and select that folder once.");
console.log("Grant GrammarNazi Accessibility permission and keep the project’s models folder in place.");
