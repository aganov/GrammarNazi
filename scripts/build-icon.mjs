import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const folder = await mkdtemp(join(tmpdir(), "grammarnazi-icon-"));
const iconset = join(folder, "GrammarNazi.iconset");
const source = resolve("assets/app-icon.png");
try {
  await mkdir(iconset);
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      const pixels = String(size * scale);
      const name = `icon_${size}x${size}${scale === 2 ? "@2x" : ""}.png`;
      execFileSync("/usr/bin/sips", ["-z", pixels, pixels, source, "--out", join(iconset, name)], { stdio: "ignore" });
    }
  }
  execFileSync("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", resolve("assets/app-icon.icns")], { stdio: "inherit" });
  execFileSync("/usr/bin/sips", ["-z", "64", "64", source, "--out", resolve("assets/app-icon-64.png")], { stdio: "ignore" });
} finally { await rm(folder, { recursive: true, force: true }); }
console.log("Generated macOS icon and 64px launcher icon from assets/app-icon.png.");
