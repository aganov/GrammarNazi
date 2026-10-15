import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { access, chmod, cp, mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
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
  const response = await fetch(url, { headers: { "User-Agent": "grammarly-local-setup" }, signal: AbortSignal.timeout(30 * 60 * 1000) });
  if (!response.ok || !response.body) throw new Error(`Download failed: HTTP ${response.status} for ${url}`);
  const partial = destination + ".partial";
  try {
    await pipeline(Readable.fromWeb(response.body), createWriteStream(partial));
    if (expected && await hash(partial) !== expected) throw new Error(`Checksum mismatch for ${destination}`);
    await rename(partial, destination);
  } catch (error) { await rm(partial, { force: true }); throw error; }
}
async function findServer(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === "llama-server") return directory;
    if (entry.isDirectory()) { const found = await findServer(join(directory, entry.name)); if (found) return found; }
  }
}

if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("The packaged runtime requires an Apple Silicon Mac.");
await mkdir("vendor", { recursive: true });
const stamp = `vendor/llama/${tag}.stamp`;
let installed = false;
try { await access(stamp); await access("vendor/llama/llama-server"); installed = true; } catch {}
if (!installed) {
  const release = await fetch(`https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${tag}`, { headers: { "User-Agent": "grammarly-local-setup" } });
  if (!release.ok) throw new Error(`Could not read llama.cpp release: HTTP ${release.status}`);
  const metadata = await release.json();
  const asset = metadata.assets.find((a) => /macos-arm64\.(tar\.gz|zip)$/.test(a.name));
  if (!asset || !asset.digest?.startsWith("sha256:")) throw new Error("No checksummed Apple Silicon runtime in the pinned release.");
  const archive = join("vendor", asset.name);
  await download(asset.browser_download_url, archive, asset.digest.slice(7));
  const extract = "vendor/extracted";
  await mkdir(extract, { recursive: true });
  if (archive.endsWith(".zip")) execFileSync("/usr/bin/ditto", ["-x", "-k", archive, extract]);
  else execFileSync("/usr/bin/tar", ["-xzf", archive, "-C", extract]);
  const directory = await findServer(extract);
  if (!directory) throw new Error("llama-server was not found in the release archive.");
  await cp(directory, "vendor/llama", { recursive: true, dereference: true });
  await download(`https://raw.githubusercontent.com/ggml-org/llama.cpp/${tag}/LICENSE`, "vendor/llama/LICENSE");
  await chmod("vendor/llama/llama-server", 0o755);
  execFileSync(resolve("vendor/llama/llama-server"), ["--version"], { stdio: "inherit" });
  await writeFile(stamp, asset.digest + "\n");
  await rm(extract, { recursive: true, force: true });
}
if (!process.argv.includes("--runtime-only")) {
  await mkdir("models", { recursive: true });
  for (const model of models) await download(`https://huggingface.co/${model.repo}/resolve/${model.revision}/${model.file}`, join("models", model.file), model.sha256);
  console.log(`Models Folder preference: ${resolve("models")}`);
}
console.log("Setup complete. Run npm run build.");
