import { execFileSync } from "node:child_process";
import { access, readdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { availableParallelism } from "node:os";

export async function buildInference() {
  const source = resolve("vendor/llama.cpp-b11461");
  await access(join(source, "include/llama.h")).catch(() => { throw new Error("Run npm run setup before building."); });
  const cmake = process.env.CMAKE || "cmake";
  try { execFileSync(cmake, ["--version"], { stdio: "ignore" }); }
  catch { throw new Error("CMake 3.24+ is required. Install CMake or set CMAKE to its executable path."); }
  const build = resolve("vendor/inference-build");
  execFileSync(cmake, ["-S", "native/inference", "-B", build, `-DLLAMA_SOURCE_DIR=${source}`,
    "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0"], { stdio: "inherit" });
  execFileSync(cmake, ["--build", build, "--target", "grammarnazi-inference", "-j", String(Math.min(8, availableParallelism()))], { stdio: "inherit" });
  const archives = [];
  async function collect(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && entry.name !== "CMakeFiles") await collect(path);
      else if (entry.isFile() && entry.name.endsWith(".a")) archives.push(path);
    }
  }
  await collect(build);
  const library = resolve("vendor/libgrammarnazi-inference.a");
  execFileSync("/usr/bin/libtool", ["-static", "-o", library, ...archives.sort()], { stdio: "inherit" });
  return ["-import-objc-header", resolve("native/inference/Inference.h"), library, "-lc++",
    "-framework", "Accelerate", "-framework", "Metal", "-framework", "MetalKit"];
}
