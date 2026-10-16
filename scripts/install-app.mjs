import { cp, mkdir, rename, rm } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";

// Stage and verify the complete bundle, then swap it into place. Keep recovery
// data only for the duration of the swap; successful installs leave no archives.
export async function installApp(source, destination, verify) {
  const directory = dirname(destination);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const staging = join(directory, `.GrammarNazi-stage-${randomUUID()}.app`);
  const swap = join(directory, `.GrammarNazi-swap-${randomUUID()}.app`);
  let swapped = false;
  let installed = false;
  let completed = false;
  try {
    await cp(source, staging, { recursive: true, dereference: true });
    await verify(staging);
    try { await rename(destination, swap); swapped = true; }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    try {
      await rename(staging, destination);
      installed = true;
      await verify(destination);
      completed = true;
    } catch (error) {
      if (installed) await rm(destination, { recursive: true, force: true });
      if (swapped) { await rename(swap, destination); swapped = false; }
      throw error;
    }
  } finally {
    await rm(staging, { recursive: true, force: true });
    if (completed && swapped) await rm(swap, { recursive: true, force: true });
  }
}
