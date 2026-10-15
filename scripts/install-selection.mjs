import { cp, mkdir, access, rename, rm } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import { execFileSync } from "node:child_process";

const destination = join(homedir(), "Applications");
const dataFolder = join(homedir(), "Library/Application Support/GrammarNazi");
const app = join(destination, "GrammarNazi.app");
const legacyApp = join(homedir(), "Library/Application Support/Grammarly Local/Grammarly Local.app");
const launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
await access("dist/GrammarNazi.app/Contents/MacOS/GrammarNazi");
await access("models/Qwen3.5-4B-Q4_K_M.gguf");
await mkdir(destination, { recursive: true, mode: 0o700 });
await mkdir(dataFolder, { recursive: true, mode: 0o700 });
// Verify a fresh bundle before replacing the installed directory. Merging app
// folders leaves obsolete executables behind and breaks the resource signature.
let previousApp = false, backupExists = false;
try { await access(app); previousApp = true; } catch {}
try { await access(join(dataFolder, "previous-app")); backupExists = true; } catch {}
const staging = join(destination, `.GrammarNazi-install-${randomUUID()}.app`);
const previous = join(dataFolder, backupExists ? `.replaced-app-${randomUUID()}` : "previous-app");
try {
  await cp("dist/GrammarNazi.app", staging, { recursive: true, dereference: true });
  execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", staging], { stdio: "inherit" });
  if (previousApp) await rename(app, previous);
  try { await rename(staging, app); }
  catch (error) { if (previousApp) await rename(previous, app); throw error; }
} finally { await rm(staging, { recursive: true, force: true }); }
if (previousApp && backupExists) await rm(previous, { recursive: true, force: true });
execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", app], { stdio: "inherit" });
execFileSync(resolve("dist/install-commands"), [app, join(dataFolder, "tinycast-custom-commands-backup.json")], { stdio: "inherit" });
let legacyExists = false;
try { await access(legacyApp); legacyExists = true; } catch {}
if (legacyExists) {
  execFileSync(launchServices, ["-u", legacyApp], { stdio: "inherit" });
  await rename(legacyApp, join(dataFolder, `previous-app-grammarly-${Date.now()}`));
}
execFileSync(launchServices, ["-f", app], { stdio: "inherit" });
console.log(`Native app: ${app}`);
console.log("One-time setup: grant GrammarNazi Accessibility permission. Keep the project’s models folder in place.");
