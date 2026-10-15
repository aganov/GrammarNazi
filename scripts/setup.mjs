import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, rename, rm } from "node:fs/promises";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { execFileSync } from "node:child_process";
import { join, resolve } from "node:path";

const tag = "b11461"; // Pin the native runtime for reproducible installs.
const models = [
  { repo: "unsloth/Qwen3.5-4B-GGUF", revision: "e87f176479d0855a907a41277aca2f8ee7a09523", file: "Qwen3.5-4B-Q4_K_M.gguf", sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4" },
];
async function hash(path) {
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(path)) digest.update(chunk);
  return digest.digest("hex");
}
async function download(url, destination, expected) {
  try { if (expected && await hash(destination) === expected) { console.log(`Verified ${destination}`); return; } } catch { /* Not downloaded. */ }
  console.log(`Downloading ${destination}`);
  const response = await fetch(url, { headers: { "User-Agent": "grammarnazi-setup" }, signal: AbortSignal.timeout(30 * 60 * 1000) });
  if (!response.ok || !response.body) throw new Error(`Download failed: HTTP ${response.status} for ${url}`);
  const partial = destination + ".partial";
  try {
    await pipeline(Readable.fromWeb(response.body), createWriteStream(partial));
    if (expected && await hash(partial) !== expected) throw new Error(`Checksum mismatch for ${destination}`);
    await rename(partial, destination);
  } catch (error) { await rm(partial, { force: true }); throw error; }
}
if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("Build on an Apple Silicon Mac.");
await mkdir("vendor", { recursive: true });
// Verify the complete source archive before extraction; headers and libraries share one revision.
const archive = `vendor/llama-${tag}-source.tar.gz`;
await download(`https://codeload.github.com/ggml-org/llama.cpp/tar.gz/refs/tags/${tag}`, archive,
  "9c1ec2a69b3e56c3ad105ef0236f272a0e6937df5219c16f9cf6f7df8225cf51");
await rm(`vendor/llama.cpp-${tag}`, { recursive: true, force: true });
execFileSync("/usr/bin/tar", ["-xzf", archive, "-C", "vendor"], { stdio: "inherit" });
if (!process.argv.includes("--runtime-only")) {
  await mkdir("models", { recursive: true });
  for (const model of models) await download(`https://huggingface.co/${model.repo}/resolve/${model.revision}/${model.file}`, join("models", model.file), model.sha256);
  console.log(`Model directory: ${resolve("models")}`);
}
console.log("Setup complete. Run npm run build.");
