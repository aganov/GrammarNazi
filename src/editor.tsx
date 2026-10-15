import { Action, ActionPanel, Clipboard, Color, Detail, Form, Icon, LaunchProps, List, Toast, environment, getPreferenceValues, getSelectedText, openExtensionPreferences, showToast, useNavigation } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { EditAction, Tone, editText, literalMarkdown, validateInput } from "./engine";
import { nativeInference } from "./native";

type Preferences = { modelsDirectory: string; generationModel?: string; tone?: Tone };
type Props = LaunchProps<{ arguments: { text?: string } }> & { action: EditAction };
type Result = { text: string; original: string; action: EditAction; tone: Tone };
const titles: Record<EditAction, string> = { grammar: "Fix Grammar", rewrite: "Rewrite" };

function SettingsAction() {
  return <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} shortcut={{ modifiers: ["cmd"], key: "," }} />;
}

function FullResult({ result }: { result: Result }) {
  return <Detail navigationTitle={titles[result.action]} markdown={`## Result\n\n${literalMarkdown(result.text)}\n\n## Original\n\n${literalMarkdown(result.original)}`} actions={
    <ActionPanel>
      <Action.Paste title="Paste Result" content={result.text} />
      <Action.CopyToClipboard title="Copy Result" content={result.text} shortcut={{ modifiers: ["cmd", "shift"], key: "c" }} />
    </ActionPanel>
  } />;
}

function MultilineInput({ initialText, onSave }: { initialText: string; onSave: (text: string) => void }) {
  const [text, setText] = useState(initialText);
  const { pop } = useNavigation();
  return <Form navigationTitle="Edit Text" actions={
    <ActionPanel>
      <Action.SubmitForm title="Use Text" onSubmit={(values: { text: string }) => { onSave(values.text); pop(); }} />
    </ActionPanel>
  }>
    <Form.TextArea id="text" title="Text" value={text} onChange={setText} placeholder="Enter your passage…" />
  </Form>;
}

export function Editor({ action: initialAction, arguments: args, fallbackText }: Props) {
  const preferences = getPreferenceValues<Preferences>();
  const launchText = args?.text?.trim() ? args.text : fallbackText || "";
  const [text, setText] = useState(launchText);
  const [tone, setTone] = useState<Tone>(preferences.tone || "natural");
  const [loading, setLoading] = useState(true);
  const [result, setResult] = useState<Result>();
  const [error, setError] = useState<string>();
  const [selectedId, setSelectedId] = useState<string>(initialAction);
  const active = useRef(true);
  const busy = useRef(false);
  const initialized = useRef(false);
  // Update synchronously in input handlers, before React renders. This prevents
  // delayed selection reads and inference responses from overwriting a newer draft.
  const draft = useRef({ text: launchText, tone, revision: 0, textRevision: 0 });

  function changeText(value: string) {
    if (value === draft.current.text) return;
    draft.current = { ...draft.current, text: value, revision: draft.current.revision + 1, textRevision: draft.current.textRevision + 1 };
    setText(value); setResult(undefined); setError(undefined);
    setSelectedId(initialAction);
  }

  function changeTone(value: string) {
    if (value === draft.current.tone) return;
    draft.current = { ...draft.current, tone: value as Tone, revision: draft.current.revision + 1 };
    setTone(value as Tone); setResult(undefined); setError(undefined);
    setSelectedId("rewrite");
  }

  async function run(action: EditAction) {
    if (busy.current) return;
    const input = { ...draft.current };
    try { validateInput(input.text); } catch (e) { setError((e as Error).message); return; }
    busy.current = true;
    setError(undefined); setResult(undefined); setLoading(true);
    try {
      const output = await editText(input.text, action, input.tone, nativeInference(environment.assetsPath, preferences.modelsDirectory, preferences.generationModel));
      if (active.current && input.revision === draft.current.revision) {
        setResult({ text: output, original: input.text, action, tone: input.tone });
        setSelectedId("result");
      }
    } catch (e) {
      if (active.current && input.revision === draft.current.revision) setError(e instanceof Error ? e.message : String(e));
    } finally {
      busy.current = false;
      if (active.current) setLoading(false);
    }
  }

  useEffect(() => {
    active.current = true;
    if (!initialized.current) {
      initialized.current = true;
      const initialTextRevision = draft.current.textRevision;
      void (async () => {
        let input = launchText;
        if (!input.trim()) {
          try { input = await getSelectedText(); } catch { /* Keep the input available for manual entry. */ }
        }
        if (!active.current) return;
        // The user may have already typed while Accessibility was reading the selection.
        if (initialTextRevision !== draft.current.textRevision) { if (!busy.current) setLoading(false); return; }
        if (input.trim()) {
          changeText(input);
          await run(initialAction);
        } else setLoading(false);
      })();
    }
    return () => { active.current = false; };
  }, []);

  async function useClipboard() {
    const revision = draft.current.revision;
    try {
      const input = await Clipboard.readText();
      if (active.current && revision === draft.current.revision && input?.trim()) changeText(input);
    } catch (e) {
      await showToast({ style: Toast.Style.Failure, title: "Couldn't read clipboard", message: String(e) });
    }
  }

  const inputActions = <>
    <Action.Push title="Edit Multiline Text" icon={Icon.Pencil} target={<MultilineInput initialText={text} onSave={changeText} />} shortcut={{ modifiers: ["cmd"], key: "e" }} />
    <Action title="Use Clipboard Text" icon={Icon.Clipboard} onAction={useClipboard} shortcut={{ modifiers: ["cmd", "shift"], key: "v" }} />
    <SettingsAction />
  </>;
  const resultActions = result && <>
    <Action.Paste title="Paste Result" content={result.text} />
    <Action.CopyToClipboard title="Copy Result" content={result.text} shortcut={{ modifiers: ["cmd", "shift"], key: "c" }} />
    <Action.Push title="View Full Result" icon={Icon.Document} target={<FullResult result={result} />} shortcut={{ modifiers: ["cmd"], key: "o" }} />
  </>;

  // Keep this List mounted throughout reading, editing, errors, and results.
  // Tinycast can preserve its native search field and focus across these updates.
  return <List navigationTitle="GrammarNazi" filtering={false} searchText={text} onSearchTextChange={changeText} throttle={false}
    searchBarPlaceholder="Enter text to fix or rewrite…" isLoading={loading} selectedItemId={selectedId}
    onSelectionChange={(id) => { if (id) setSelectedId(id); }} searchBarAccessory={
      <List.Dropdown tooltip="Rewrite Tone" value={tone} onChange={changeTone}>
        <List.Dropdown.Item value="natural" title="Natural" />
        <List.Dropdown.Item value="professional" title="Professional" />
        <List.Dropdown.Item value="friendly" title="Friendly" />
        <List.Dropdown.Item value="concise" title="Concise" />
      </List.Dropdown>
    }>
    <List.Section title="Result" subtitle={result ? titles[result.action] : undefined}>
      {result ? <List.Item id="result" title={result.text.replace(/\s+/g, " ").trim()} actions={
        <ActionPanel>
          {resultActions}
          <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={() => run(result.action)} shortcut={{ modifiers: ["cmd"], key: "r" }} />
          {inputActions}
        </ActionPanel>
      } /> : <List.Item id="status" icon={error ? { source: Icon.ExclamationMark, tintColor: Color.Orange } : Icon.Text}
        title={error || (loading ? (busy.current ? "Editing your text…" : "Reading selected text…") : "Your result will appear here")}
        actions={<ActionPanel><Action title={titles[initialAction]} icon={Icon.Wand} onAction={() => run(initialAction)} />{inputActions}</ActionPanel>}
      />}
    </List.Section>
    <List.Section title="Commands">
      <List.Item id="grammar" title="Fix Grammar" icon={{ source: Icon.Checkmark, tintColor: Color.Green }} actions={
        <ActionPanel>
          <Action title="Fix Grammar" icon={Icon.Checkmark} onAction={() => run("grammar")} />
          {resultActions}
          {inputActions}
        </ActionPanel>
      } />
      <List.Item id="rewrite" title="Rewrite" icon={{ source: Icon.Pencil, tintColor: Color.Blue }} actions={
        <ActionPanel>
          <Action title="Rewrite" icon={Icon.Pencil} onAction={() => run("rewrite")} />
          {resultActions}
          {inputActions}
        </ActionPanel>
      } />
    </List.Section>
  </List>;
}
