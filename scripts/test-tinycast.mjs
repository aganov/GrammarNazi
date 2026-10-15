import assert from "node:assert/strict";
import fs from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";

const runtime = process.env.TINYCAST_RUNTIME || "/Applications/Tinycast.app/Contents/Resources/RaycastRuntime.generated.js";
if (!fs.existsSync(runtime)) throw new Error("Install Tinycast or set TINYCAST_RUNTIME to its RaycastRuntime.generated.js.");
const runtimeSource = fs.readFileSync(runtime, "utf8");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const b64 = (value) => Buffer.from(value).toString("base64");

async function launch(command, { text = "", selectedText = "", fallbackText = "", fail = false, deferInference = false, deferSelection = false, deferClipboard = false } = {}) {
  let tree;
  const errors = [], calls = [], timers = new Map(), files = new Map();
  const pending = [], requests = [];
  let context;
  const host = {
    log(level, message) { if (level === "error") errors.push(message); },
    render(id, json) { tree = JSON.parse(json); },
    failed(id, message) { errors.push(message); },
    navigationDepthChanged() {}, finished() {}, fieldCommand() {},
    startTimer(id, ms, repeats) {
      const callback = () => context.__tinycast.fireTimer(id);
      timers.set(id, repeats ? setInterval(callback, ms) : setTimeout(callback, ms));
    },
    clearTimer(id) { clearTimeout(timers.get(id)); clearInterval(timers.get(id)); timers.delete(id); },
    invokeSync(group, method, json) {
      const args = JSON.parse(json);
      try {
        let value;
        if (group === "fs" && method === "exists") value = true;
        else if (group === "fs" && method === "mkdtemp") value = args[0] + "fixture";
        else if (group === "fs" && method === "writeFile") files.set(args[0], Buffer.from(args[1], "base64").toString());
        else if (group === "fs" && method === "remove") files.delete(args[0]);
        else throw new Error(`Unexpected sync call: ${group}.${method}`);
        return JSON.stringify({ ok: true, value });
      } catch (error) { return JSON.stringify({ ok: false, error: error.message }); }
    },
    invoke(id, group, method, json) {
      const args = JSON.parse(json);
      calls.push({ group, method, args });
      queueMicrotask(() => {
        try {
          let value;
          if (group === "system" && method === "selectedText") {
            if (deferSelection) { pending.push({ kind: "selection", settle: () => context.__tinycast.settle(id, true, JSON.stringify(selectedText)) }); return; }
            value = selectedText;
          }
          else if (group === "clipboard" && method === "readText") {
            if (deferClipboard) { pending.push({ kind: "clipboard", settle: () => context.__tinycast.settle(id, true, JSON.stringify("clipboard text")) }); return; }
            value = "clipboard text";
          }
          else if (group === "clipboard" || group === "window") value = null;
          else if (group === "proc" && method === "run") {
            const request = args[0];
            assert.equal(request.shell, false);
            assert.equal(request.args.length, 3);
            const body = JSON.parse(files.get(request.args[2]));
            requests.push(body);
            assert.equal(body.stream, false);
            assert.deepEqual(body.chat_template_kwargs, { enable_thinking: false });
            value = fail ? { status: 1, stdout: "", stderr: b64("Model is missing") }
              : { status: 0, stdout: b64(JSON.stringify({ choices: [{ finish_reason: "stop", message: { content: "Edited text." } }] })), stderr: "" };
            if (deferInference) { pending.push({ kind: "inference", settle: () => context.__tinycast.settle(id, true, JSON.stringify(value)) }); return; }
          } else throw new Error(`Unexpected call: ${group}.${method}`);
          context.__tinycast.settle(id, true, JSON.stringify(value));
        } catch (error) { context.__tinycast.settle(id, false, error.message); }
      });
    },
  };
  context = vm.createContext({ __tinycastHost: host, __tinycastCompile: (source, filename) => vm.runInContext(`(function(exports, require, module, __filename, __dirname) {\n${source}\n})`, context, { filename }) });
  vm.runInContext(runtimeSource, context, { filename: runtime });
  const config = { node: { tmpdir: "/private/tmp", cwd: process.cwd() }, environment: { assetsPath: resolve("dist/assets") },
    preferences: { modelsDirectory: "/fixture/models", tone: "natural" }, launchProps: { arguments: { text }, fallbackText } };
  context.__tinycast.boot(JSON.stringify(config));
  context.__tinycast.start("test", fs.readFileSync(`dist/${command}.js`, "utf8"), resolve(`dist/${command}.js`), resolve("dist"), "view", JSON.stringify(config));
  const nodes = () => {
    const result = [];
    function walk(value) {
      if (!value || typeof value !== "object") return;
      if (value.type) result.push(value);
      for (const item of Object.values(value)) if (typeof item === "object") {
        if (Array.isArray(item)) item.forEach(walk); else walk(item);
      }
    }
    walk(tree); return result;
  };
  async function until(predicate) {
    for (let i = 0; i < 100; i++) {
      assert.deepEqual(errors, [], errors.join("\n"));
      if (predicate(nodes())) return;
      await delay(20);
    }
    throw new Error(`No expected render: ${JSON.stringify(tree)}`);
  }
  return {
    calls, files, nodes, until, pending, requests,
    async action(title) {
      const node = nodes().find((n) => n.props?.title === title && n.props?.onAction?.$fn);
      assert.ok(node, `Missing action ${title}`);
      assert.equal(context.__tinycast.dispatch("test", node.props.onAction.$fn, "[]"), "1");
      await delay(40);
    },
    async change(type, prop, value) {
      const node = nodes().find((n) => n.type === type && n.props?.[prop]?.$fn);
      assert.ok(node, `Missing ${type}.${prop}`);
      assert.equal(context.__tinycast.dispatch("test", node.props[prop].$fn, JSON.stringify([value])), "1");
      await delay(40);
    },
    async release(kind) {
      const index = pending.findIndex((item) => item.kind === kind);
      assert.ok(index >= 0, `No pending ${kind}`);
      pending.splice(index, 1)[0].settle();
      await delay(40);
    },
    async back() { assert.equal(context.__tinycast.popNavigation("test"), "1"); await delay(40); },
    stop() { context.__tinycast.stop("test"); for (const timer of timers.values()) { clearTimeout(timer); clearInterval(timer); } },
  };
}

for (const command of ["fix-grammar", "rewrite"]) {
  const app = await launch(command, { selectedText: "A selected passage.", deferInference: true });
  try {
    await app.until(() => app.pending.some((item) => item.kind === "inference"));
    const list = app.nodes().find((n) => n.type === "List");
    assert.equal(list.props.searchText, "A selected passage.");
    assert.equal(list.props.isLoading, true);
    assert.equal(list.props.filtering, false);
    assert.ok(app.nodes().some((n) => n.type === "List.Dropdown"));
    await app.release("inference");
    await app.until((nodes) => nodes.some((n) => n.type === "List.Item" && n.props.id === "result"));
    const finished = app.nodes().find((n) => n.type === "List");
    assert.equal(finished.id, list.id, "Same native List across loading and results");
    assert.equal(finished.props.searchText, "A selected passage.");
    assert.equal(finished.props.selectedItemId, "result");
    assert.equal(app.calls.filter((c) => c.group === "proc").length, 1);
    assert.equal(app.files.size, 0, "Temporary text removed");
    assert.equal(app.calls.filter((c) => c.group === "clipboard").length, 0, "No automatic clipboard access");
    await app.action("Paste Result");
    assert.equal(app.calls.find((c) => c.group === "clipboard" && c.method === "paste")?.args[0].text, "Edited text.");
    console.log(`PASS ${command}: persistent input and tone controls through loading, result, and paste`);
  } finally { app.stop(); }
}
const manual = await launch("rewrite");
try {
  await manual.until((nodes) => nodes.some((n) => n.type === "List" && !n.props.isLoading));
  await manual.change("List", "onSearchTextChange", "A new draft.");
  await manual.change("List.Dropdown", "onChange", "professional");
  assert.equal(manual.nodes().find((n) => n.type === "List").props.searchText, "A new draft.");
  assert.equal(manual.nodes().filter((n) => n.type === "List.Item" && ["grammar", "rewrite"].includes(n.props.id)).length, 2);
  await manual.action("Use Clipboard Text");
  await manual.until((nodes) => nodes.some((n) => n.type === "List" && n.props.searchText === "clipboard text"));
  await manual.action("Rewrite");
  await manual.until((nodes) => nodes.some((n) => n.type === "List.Item" && n.props.id === "result"));
  assert.match(manual.requests[0].messages[0].content, /professional tone/);
  await manual.action("View Full Result");
  await manual.until((nodes) => nodes.some((n) => n.type === "Detail" && n.props.markdown?.includes("Edited text.")));
  await manual.back();
  await manual.until((nodes) => nodes.some((n) => n.type === "List" && n.props.searchText === "clipboard text"));
  await manual.action("Edit Multiline Text");
  await manual.until((nodes) => nodes.some((n) => n.type === "Form.TextArea"));
  await manual.change("Form.TextArea", "onTinycastChange", "First paragraph.\n\nSecond paragraph.");
  await manual.action("Use Text");
  await manual.until((nodes) => nodes.some((n) => n.type === "List" && n.props.searchText === "First paragraph.\n\nSecond paragraph."));
  assert.ok(!manual.nodes().some((n) => n.type === "List.Item" && n.props.id === "result"), "Editing invalidates the old result");
  console.log("PASS manual input, tone, clipboard, full preview, and multiline editing preserve the draft");
} finally { manual.stop(); }
const failed = await launch("fix-grammar", { text: "Argument text.", selectedText: "Ignored selection", fail: true });
try {
  await failed.until((nodes) => nodes.some((n) => n.type === "List.Item" && n.props.title?.includes("Model is missing")));
  assert.ok(!failed.calls.some((c) => c.method === "selectedText"), "Argument takes priority");
  assert.equal(failed.files.size, 0);
  assert.equal(failed.nodes().find((n) => n.type === "List").props.searchText, "Argument text.");
  console.log("PASS model errors preserve input and clean temporary text");
} finally { failed.stop(); }

const selectionRace = await launch("fix-grammar", { selectedText: "Old selection", deferSelection: true, deferInference: true });
try {
  await selectionRace.until(() => selectionRace.pending.some((item) => item.kind === "selection"));
  await selectionRace.change("List", "onSearchTextChange", "Already typing a new draft");
  await selectionRace.action("Fix Grammar");
  await selectionRace.release("selection");
  assert.equal(selectionRace.nodes().find((n) => n.type === "List").props.searchText, "Already typing a new draft");
  assert.equal(selectionRace.nodes().find((n) => n.type === "List").props.isLoading, true, "Selection read does not clear an active inference spinner");
  assert.equal(selectionRace.requests.length, 1, "Late selection does not replace or submit typed text");
  assert.equal(selectionRace.requests[0].messages.at(-1).content, "Already typing a new draft");
  await selectionRace.release("inference");
  console.log("PASS delayed selection cannot overwrite typed text");
} finally { selectionRace.stop(); }

const inferenceRace = await launch("rewrite", { text: "Original draft", deferInference: true });
try {
  await inferenceRace.until(() => inferenceRace.pending.some((item) => item.kind === "inference"));
  const listId = inferenceRace.nodes().find((n) => n.type === "List").id;
  await inferenceRace.action("Rewrite");
  assert.equal(inferenceRace.requests.length, 1, "Repeated Return does not submit twice");
  await inferenceRace.change("List", "onSearchTextChange", "Updated draft");
  await inferenceRace.release("inference");
  assert.equal(inferenceRace.nodes().find((n) => n.type === "List").id, listId);
  assert.equal(inferenceRace.nodes().find((n) => n.type === "List").props.searchText, "Updated draft");
  assert.ok(!inferenceRace.nodes().some((n) => n.type === "List.Item" && n.props.id === "result"));
  assert.ok(!inferenceRace.nodes().some((n) => n.type === "Action" && n.props.title === "Paste Result"));
  await inferenceRace.action("Rewrite");
  assert.equal(inferenceRace.requests[1].messages.at(-1).content, "Updated draft");
  await inferenceRace.change("List.Dropdown", "onChange", "friendly");
  await inferenceRace.release("inference");
  assert.ok(!inferenceRace.nodes().some((n) => n.type === "List.Item" && n.props.id === "result"), "Late results from an old tone are also discarded");
  console.log("PASS draft edits and tone changes reject stale results without remounting the input");
} finally { inferenceRace.stop(); }

const clipboardRace = await launch("fix-grammar", { deferClipboard: true });
try {
  await clipboardRace.until((nodes) => nodes.some((n) => n.type === "List" && !n.props.isLoading));
  await clipboardRace.action("Use Clipboard Text");
  await clipboardRace.change("List", "onSearchTextChange", "Typed while reading clipboard");
  await clipboardRace.release("clipboard");
  assert.equal(clipboardRace.nodes().find((n) => n.type === "List").props.searchText, "Typed while reading clipboard");
  console.log("PASS delayed clipboard reads cannot overwrite typed text");
} finally { clipboardRace.stop(); }

const selectedTone = await launch("rewrite", { selectedText: "Selected passage", deferSelection: true });
try {
  await selectedTone.until(() => selectedTone.pending.some((item) => item.kind === "selection"));
  await selectedTone.change("List.Dropdown", "onChange", "friendly");
  await selectedTone.release("selection");
  await selectedTone.until((nodes) => nodes.some((n) => n.type === "List.Item" && n.props.id === "result"));
  assert.equal(selectedTone.nodes().find((n) => n.type === "List").props.searchText, "Selected passage");
  assert.match(selectedTone.requests[0].messages[0].content, /friendly tone/);
  console.log("PASS tone changes during selection capture preserve the selected passage");
} finally { selectedTone.stop(); }
