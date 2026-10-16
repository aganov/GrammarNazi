import { execFileSync } from "node:child_process";
import { mkdir, readFile } from "node:fs/promises";
import assert from "node:assert/strict";
import { resolve, join } from "node:path";
import { buildInference } from "./inference-build.mjs";
import { tmpdir } from "node:os";

execFileSync(process.execPath, ["--test", "tests/launcher_commands.test.mjs", "tests/install_app.test.mjs"], { stdio: "inherit" });

const swiftCache = join(tmpdir(), "grammarnazi-swift-cache");
await mkdir(swiftCache, { recursive: true });
execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", swiftCache, "native/selection/Markdown.swift", "native/selection/Editing.swift", "native/selection/CustomCommands.swift", "tests/selection_core.swift", "-o", "vendor/selection-core-tests"], { stdio: "inherit" });
execFileSync(resolve("vendor/selection-core-tests"), [], { stdio: "inherit" });
execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", swiftCache, "native/selection/Markdown.swift", "native/selection/Editing.swift", "native/selection/ModelLifecycle.swift", "native/selection/CommandRouter.swift", "tests/resident_lifecycle.swift", "-o", "vendor/resident-lifecycle-tests"], { stdio: "inherit" });
execFileSync(resolve("vendor/resident-lifecycle-tests"), [], { stdio: "inherit" });
if (process.argv.includes("--inference") || process.argv.includes("--models")) {
  const inferenceFlags = await buildInference();
  execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", swiftCache, ...inferenceFlags, "native/selection/Markdown.swift", "native/selection/Editing.swift", "native/selection/ModelLifecycle.swift", "native/selection/Inference.swift", "tests/embedded_runtime.swift", "-o", "vendor/inference-tests"], { stdio: "inherit" });
  execFileSync(resolve("vendor/inference-tests"), [], { stdio: "inherit" });
  if (process.argv.includes("--models")) {
    execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", swiftCache, ...inferenceFlags, "native/selection/Inference.swift", "native/selection/Markdown.swift", "native/selection/Editing.swift", "native/selection/ModelLifecycle.swift", "tests/selection_models.swift", "-o", "vendor/selection-model-tests"], { stdio: "inherit" });
    execFileSync(resolve("vendor/selection-model-tests"), [resolve("dist/GrammarNazi.app/Contents/Resources")], { stdio: "inherit" });
  }
}
if (process.argv.includes("--preview")) {
  const inferenceFlags = await buildInference();
  execFileSync("/usr/bin/xcrun", ["swiftc", "-D", "RESIDENT_TESTS", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", swiftCache, ...inferenceFlags, "native/selection/ModelLifecycle.swift", "native/selection/CommandRouter.swift", "native/selection/Inference.swift", "native/selection/Markdown.swift", "native/selection/Editing.swift", "native/selection/MarkdownPreview.swift", "native/selection/Selection.swift", "native/selection/SelectionApp.swift", "tests/resident_app.swift", "-o", "vendor/resident-app-tests"], { stdio: "inherit" });
  execFileSync(resolve("vendor/resident-app-tests"), [resolve("dist/GrammarNazi.app/Contents/Resources")], { stdio: "inherit", timeout: 30000 });
  execFileSync(resolve("dist/GrammarNazi.app/Contents/MacOS/GrammarNazi"), ["--action", "rewrite", "--render-preview", resolve("vendor/selection-preview.png")], { stdio: "inherit", timeout: 15000 });
  for (const raw of [false, true]) {
    const output = resolve(`vendor/selection-long-${raw ? "markdown" : "preview"}.png`);
    execFileSync(resolve("dist/GrammarNazi.app/Contents/MacOS/GrammarNazi"), ["--action", "rewrite", "--fixture", resolve("tests/fixtures/long-markdown.md"), "--render-preview", output, ...(raw ? ["--source-preview"] : [])], { stdio: "inherit", timeout: 15000 });
    const report = JSON.parse(await readFile(output + ".json", "utf8"));
    assert.ok(report.textWidth <= report.containerWidth + 1, "Long words and URLs must wrap within the text container");
    assert.ok(report.documentHeight > report.viewportHeight, "Long text must grow the scrollable document");
    assert.equal(report.horizontalScroller, false);
    if (raw) assert.equal(report.text, await readFile("tests/fixtures/long-markdown.md", "utf8"));
    console.log(`PASS long ${raw ? "Markdown" : "preview"} wraps and scrolls (${output})`);
  }
  console.log("Rendered native previews in vendor/selection-*.png");
}
