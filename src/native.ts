import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync, unlinkSync, rmdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GENERATION_FILE, Inference } from "./engine";

export function nativeInference(assetsPath: string, modelsDirectory: string, generationModel?: string): Inference {
  return async (body) => {
    const helper = join(assetsPath, "grammarly-helper");
    const server = join(assetsPath, "llama", "llama-server");
    const model = generationModel || join(modelsDirectory, GENERATION_FILE);
    if (!existsSync(helper) || !existsSync(server)) throw new Error("Local runtime is missing. Run npm run setup, then npm run build and import dist into Tinycast.");
    if (!existsSync(model)) throw new Error("Model file is missing. Run npm run setup and select its models folder in extension preferences.");
    const folder = mkdtempSync(join(tmpdir(), "grammarly-local-"));
    const request = join(folder, "request.json");
    try {
      // Text stays out of the process arguments; the private file is removed after each request.
      writeFileSync(request, JSON.stringify(body), { mode: 0o600 });
      const stdout = await new Promise<string>((resolve, reject) => {
        execFile(helper, [server, model, request], { timeout: 240000, maxBuffer: 2 * 1024 * 1024 }, (error, stdout, stderr) => {
          if (error) reject(new Error(error.killed ? "Local inference timed out. Try a shorter passage." : stderr.trim() || "Local inference failed."));
          else resolve(stdout);
        });
      });
      try { return JSON.parse(stdout); } catch { throw new Error("The local helper returned an invalid response."); }
    } finally {
      if (existsSync(request)) unlinkSync(request);
      rmdirSync(folder);
    }
  };
}
