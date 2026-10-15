import assert from "node:assert/strict";
import { test } from "node:test";
import { editText, literalMarkdown, parseCompletion, validateInput } from "../src/engine";

test("validates input without sending empty or oversized text to the model", () => {
  assert.throws(() => validateInput(" \n"), /Enter or select/);
  assert.throws(() => validateInput("a".repeat(12001)), /shorter passage/);
});
test("retains whitespace and formatting, rejecting truncated or empty completions", () => {
  assert.equal(parseCompletion({ choices: [{ finish_reason: "stop", message: { content: "**Hello.**" } }] }, "  hi\n"), "  **Hello.**\n");
  assert.throws(() => parseCompletion({ choices: [{ finish_reason: "length" }] }, "hi"), /output limit/);
  assert.throws(() => parseCompletion({ choices: [{ finish_reason: "stop", message: { content: "" } }] }, "hi"));
});
test("grammar and rewrite send distinct instructions and the full passage to Qwen directly", async () => {
  for (const action of ["grammar", "rewrite"] as const) {
    const calls: Record<string, unknown>[] = [];
    const input = "Send me an update. ".repeat(100);
    const result = await editText(input, action, "professional", async (body) => {
      calls.push(body);
      return { choices: [{ finish_reason: "stop", message: { content: "Could you send me an update?" } }] };
    });
    assert.equal(result, "Could you send me an update? ");
    assert.equal(calls.length, 1);
    const messages = calls[0].messages as { role: string; content: string }[];
    assert.equal(messages.length, 2);
    assert.equal(messages.at(-1)?.content, input.trim());
    assert.match(messages[0].content, action === "grammar" ? /punctuation only/ : /professional tone/);
    assert.equal(calls[0].stream, false);
    assert.deepEqual(calls[0].chat_template_kwargs, { enable_thinking: false });
  }
});
test("inference failures return an actionable error without retries", async () => {
  let calls = 0;
  await assert.rejects(editText("Hello", "grammar", "natural", async () => { calls++; throw new Error("Model is missing"); }), /Model is missing/);
  assert.equal(calls, 1);
});
test("literal preview fences cannot be closed by the user's Markdown", () => {
  assert.equal(literalMarkdown("```\nhello\n```"), "````text\n```\nhello\n```\n````");
});
