import { mkdir, writeFile, chmod, cp } from "node:fs/promises";
import { join } from "node:path";

export const commands = [
  { action: "grammar", title: "Fix Grammar (Selection)", file: "fix-grammar.sh", description: "Fix grammar in selected text locally with GrammarNazi." },
  { action: "rewrite", title: "Rewrite (Selection)", file: "rewrite.sh", description: "Rewrite selected text locally with GrammarNazi." },
];

const quote = (value) => "'" + value.replaceAll("'", "'\"'\"'") + "'";

export function launchCommand(action, appPath) {
  if (!commands.some((command) => command.action === action)) throw new Error("Unknown editing action.");
  return `exec /usr/bin/open -g -n ${quote(appPath)} --args --action ${action}`;
}

export function raycastScript(action, appPath) {
  const command = commands.find((command) => command.action === action);
  if (!command) throw new Error("Unknown editing action.");
  return `#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title ${command.title}
# @raycast.mode silent
# @raycast.packageName GrammarNazi
# @raycast.icon icon.png
# @raycast.needsConfirmation false
# @raycast.description ${command.description}

${launchCommand(action, appPath)}
`;
}

export async function writeRaycastCommands(directory, appPath) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await cp(new URL("../assets/app-icon-64.png", import.meta.url), join(directory, "icon.png"));
  for (const command of commands) {
    const path = join(directory, command.file);
    await writeFile(path, raycastScript(command.action, appPath), { mode: 0o755 });
    await chmod(path, 0o755);
  }
}
