import rules from "../assets/editing-rules.json";

export type EditAction = "grammar" | "rewrite";
export type Tone = "natural" | "professional" | "friendly" | "concise";
export const MAX_INPUT_LENGTH = 12000;
export const GENERATION_FILE = "Qwen3.5-4B-Q4_K_M.gguf";
export type Inference = (body: Record<string, unknown>) => Promise<unknown>;

export function validateInput(text: string): void {
  if (!text.trim()) throw new Error("Enter or select some text first.");
  if (text.length > MAX_INPUT_LENGTH) throw new Error(`Select a shorter passage (up to ${MAX_INPUT_LENGTH.toLocaleString()} characters).`);
}

export function parseCompletion(response: unknown, original: string): string {
  const choice = (response as { choices?: { finish_reason?: string; message?: { content?: unknown } }[] })?.choices?.[0];
  if (choice?.finish_reason === "length") throw new Error("The model reached its output limit. Try a shorter passage.");
  if (choice?.finish_reason !== "stop" || typeof choice.message?.content !== "string" || !choice.message.content.trim()) {
    throw new Error("The generation model did not return a complete text result.");
  }
  return (original.match(/^\s*/)?.[0] ?? "") + choice.message.content.trim() + (original.match(/\s*$/)?.[0] ?? "");
}

export async function editText(text: string, action: EditAction, tone: Tone, infer: Inference): Promise<string> {
  validateInput(text);
  const instruction = action === "grammar"
    ? rules.grammar
    : rules.rewrite.replace("{tone}", tone);
  const messages = [
    { role: "system", content: `${instruction} ${rules.boundary}` },
    { role: "user", content: text.trim() },
  ];
  return parseCompletion(await infer({
    messages, stream: false, temperature: action === "grammar" ? 0.1 : 0.4,
    max_tokens: 4096, chat_template_kwargs: { enable_thinking: false }, reasoning_effort: "none",
  }), text);
}

export function literalMarkdown(text: string): string {
  const longest = Math.max(2, ...(text.match(/`+/g) ?? []).map((run) => run.length));
  const fence = "`".repeat(longest + 1);
  return `${fence}text\n${text}\n${fence}`;
}
