import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { installApp } from "../scripts/install-app.mjs";

async function fixture(run) {
  const folder = await mkdtemp(join(tmpdir(), "grammarnazi-installer-"));
  const source = join(folder, "source.app"), destination = join(folder, "Applications/GrammarNazi.app");
  try {
    await mkdir(source);
    await writeFile(join(source, "app"), "valid");
    await run({ folder, source, destination });
  } finally { await rm(folder, { recursive: true, force: true }); }
}
const verify = async (app) => assert.equal(await readFile(join(app, "app"), "utf8"), "valid");

test("Install and replace a full app bundle without retaining archives or merging files", () => fixture(async ({ source, destination }) => {
  await installApp(source, destination, verify);
  await writeFile(join(destination, "extra"), "discard");
  await installApp(source, destination, verify);
  assert.deepEqual(await readdir(destination), ["app"]);
  assert.deepEqual(await readdir(join(destination, "..")), ["GrammarNazi.app"]);
}));

test("A rejected staged bundle leaves the installed app untouched", () => fixture(async ({ source, destination }) => {
  await installApp(source, destination, verify);
  await assert.rejects(installApp(source, destination, () => { throw new Error("Invalid signature"); }), /Invalid signature/);
  await verify(destination);
  assert.deepEqual(await readdir(join(destination, "..")), ["GrammarNazi.app"]);
}));

test("A failed installed-bundle check restores the working app and cleans temporary files", () => fixture(async ({ source, destination }) => {
  await installApp(source, destination, verify);
  await writeFile(join(source, "app"), "replacement");
  await assert.rejects(installApp(source, destination, async (app) => {
    if (app === destination) throw new Error("Verification failed");
  }), /Verification failed/);
  await verify(destination);
  assert.deepEqual(await readdir(join(destination, "..")), ["GrammarNazi.app"]);
}));
