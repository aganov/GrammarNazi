import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { mkdir, cp, readFile, writeFile, access } from "node:fs/promises";
import { resolve } from "node:path";

if (process.platform !== "darwin") throw new Error("The native helper requires macOS.");
await mkdir("dist/assets", { recursive: true });
await mkdir("vendor/swift-cache", { recursive: true });
execFileSync("/usr/bin/xcrun", ["swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macosx15.0", "-module-cache-path", resolve("vendor/swift-cache"), "native/Helper.swift", "-o", "dist/assets/grammarly-helper"], { stdio: "inherit" });
await build({
  entryPoints: ["src/fix-grammar.tsx", "src/rewrite.tsx"], outdir: "dist", bundle: true,
  format: "cjs", platform: "node", target: "es2022", jsx: "automatic", minify: true,
  external: ["@raycast/api", "react", "react/jsx-runtime"],
});
await cp("assets", "dist/assets", { recursive: true });
await cp("LICENSE", "dist/assets/extension-LICENSE");
const manifest = JSON.parse(await readFile("package.json", "utf8"));
for (const field of ["scripts", "dependencies", "devDependencies", "$schema"]) delete manifest[field];
await writeFile("dist/package.json", JSON.stringify(manifest, null, 2) + "\n");
let runtimeAvailable = false;
try { await access("vendor/llama/llama-server"); runtimeAvailable = true; } catch {}
if (runtimeAvailable) await cp("vendor/llama", "dist/assets/llama", { recursive: true, dereference: true });
else console.warn("Runtime not downloaded yet. Run npm run setup, then rebuild before importing dist.");
console.log("Built dist/: import this folder in Tinycast → Settings → Extensions → Install → Add from folder.");
