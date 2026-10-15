import { cp, mkdir, access } from "node:fs/promises";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import { execFileSync } from "node:child_process";

const destination = join(homedir(), "Library/Application Support/Grammarly Local");
const app = join(destination, "Grammarly Local.app");
await access("dist/Grammarly Local.app/Contents/MacOS/GrammarlyLocal");
await access("models/Qwen3.5-4B-Q4_K_M.gguf");
await mkdir(destination, { recursive: true, mode: 0o700 });
// Keep a complete first-install backup of a previous native app if one exists.
let previousApp = false, backupExists = false;
try { await access(app); previousApp = true; } catch {}
try { await access(join(destination, "previous-app")); backupExists = true; } catch {}
if (previousApp && !backupExists) await cp(app, join(destination, "previous-app"), { recursive: true });
await cp("dist/Grammarly Local.app", app, { recursive: true, dereference: true });
execFileSync(resolve("dist/install-commands"), [app, join(destination, "tinycast-custom-commands-backup.json")], { stdio: "inherit" });
console.log(`Native app: ${app}`);
console.log("One-time setup: grant Grammarly Local Accessibility permission. Keep the project’s models folder in place.");
