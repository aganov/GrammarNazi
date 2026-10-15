import { execFileSync } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";

await mkdir("vendor/swift-cache", { recursive: true });
execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", resolve("vendor/swift-cache"), "native/selection/Editing.swift", "native/selection/CustomCommands.swift", "tests/selection_core.swift", "-o", "vendor/selection-core-tests"], { stdio: "inherit" });
execFileSync(resolve("vendor/selection-core-tests"), [], { stdio: "inherit" });
if (process.argv.includes("--models")) {
  execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", resolve("vendor/swift-cache"), "native/selection/Editing.swift", "tests/selection_models.swift", "-o", "vendor/selection-model-tests"], { stdio: "inherit" });
  execFileSync(resolve("vendor/selection-model-tests"), [resolve("dist/Grammarly Local.app/Contents/Resources")], { stdio: "inherit" });
}
if (process.argv.includes("--preview")) {
  execFileSync(resolve("dist/Grammarly Local.app/Contents/MacOS/GrammarlyLocal"), ["--action", "rewrite", "--render-preview", resolve("vendor/selection-preview.png")], { stdio: "inherit", timeout: 15000 });
  console.log("Rendered native preview: vendor/selection-preview.png");
}
