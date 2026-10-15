import assert from "node:assert/strict";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { editText } from "../src/engine.ts";
import { nativeInference } from "../src/native.ts";

const infer = nativeInference(resolve("dist/assets"), resolve("models"));
const cases = [
  { action: "grammar", tone: "natural", text: "She dont have the report yet, but she have sent invoice 4821.", check: (result) => {
    assert.match(result, /doesn't|does not/i);
    assert.match(result, /has sent/i);
    assert.match(result, /4821/);
  } },
  { action: "rewrite", tone: "professional", text: "I was wondering if maybe you could send me an update about ticket 4821 when you have time.", check: (result) => {
    assert.match(result, /4821/);
    assert.match(result, /update/i);
    assert.ok(result.length < 200);
  } },
  { action: "grammar", tone: "natural", text: "The deployment is scheduled for Friday at 14:30.", check: (result) => {
    assert.equal(result, "The deployment is scheduled for Friday at 14:30.");
  } },
];
for (const item of cases) {
  const start = performance.now();
  const result = await editText(item.text, item.action, item.tone, infer);
  item.check(result);
  console.log(`${item.action} (${((performance.now() - start) / 1000).toFixed(2)}s): ${result}`);
}
try {
  const running = execFileSync("/bin/ps", ["-axo", "command="], { encoding: "utf8" }).split("\n");
  assert.ok(!running.some((line) => line.includes(resolve("dist/assets/llama/llama-server")) && line.includes("--model")), "Runtime should have exited");
} catch (error) { if (error.code !== "EPERM") throw error; }
console.log("PASS real local inference and runtime cleanup");
