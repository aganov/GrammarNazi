import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { commands, raycastScript, writeRaycastCommands } from "../scripts/launcher-commands.mjs";

test("Raycast scripts launch only the requested action and keep shell syntax inert", async () => {
  const folder = await mkdtemp(join(tmpdir(), "grammarnazi-launchers-"));
  try {
    const app = join(folder, "it's $(touch INJECTED); `touch INJECTED` GrammarNazi.app");
    for (const command of commands) {
      const path = join(folder, command.file);
      const script = raycastScript(command.action, app);
      assert.match(script, /# @raycast.schemaVersion 1\n/);
      assert.match(script, /# @raycast.mode silent\n/);
      assert.match(script, /# @raycast.packageName GrammarNazi\n/);
      assert.ok(script.includes(`# @raycast.title ${command.title}\n`));
      assert.doesNotMatch(script, /@raycast.argument/);
      await writeFile(path, script);
      execFileSync("/bin/bash", ["-n", path]);
      // Record the actual shell arguments without opening an app or reading a selection.
      await writeFile(path, script.replace("exec /usr/bin/open", "printf '%s\\n'"));
      const args = execFileSync("/bin/bash", [path], { cwd: folder, encoding: "utf8" }).trimEnd().split("\n");
      assert.deepEqual(args, ["-g", "-n", app, "--args", "--action", command.action]);
    }
    assert.ok(!(await readdir(folder)).includes("INJECTED"));
    assert.throws(() => raycastScript("translate", app), /Unknown editing action/);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test("Writing Raycast commands updates paths and permissions without removing other files", async () => {
  const folder = await mkdtemp(join(tmpdir(), "grammarnazi-raycast-"));
  try {
    await writeFile(join(folder, "notes.txt"), "keep");
    await writeRaycastCommands(folder, "/Applications/GrammarNazi.app");
    await writeRaycastCommands(folder, "/a path/GrammarNazi.app");
    for (const command of commands) {
      const path = join(folder, command.file);
      assert.equal((await stat(path)).mode & 0o777, 0o755);
      assert.equal(await readFile(path, "utf8"), raycastScript(command.action, "/a path/GrammarNazi.app"));
    }
    assert.equal(await readFile(join(folder, "notes.txt"), "utf8"), "keep");
    assert.deepEqual((await readdir(folder)).sort(), ["fix-grammar.sh", "notes.txt", "rewrite.sh"]);
  } finally { await rm(folder, { recursive: true, force: true }); }
});
