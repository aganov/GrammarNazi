# GrammarNazi

Fix and rewrite selected text in Slack and other Mac apps using Tinycast **Custom Commands** and a small native preview app. Supports **Tinycast 0.9.7-sequoia on macOS 15**, with Qwen3.5-4B running locally through llama.cpp.

## Selected-text workflow

1. Select a passage in your app.
2. Run **Fix Grammar (Selection)** or **Rewrite (Selection)** from Tinycast, or assign a global shortcut to each command.
3. A floating preview shows the result. **Return / Replace** pastes over the selection, **⌘C / Copy** copies the result, and **Escape / Cancel** closes it.

The preview is a non-activating macOS panel so the original app can keep its selection. Rewrite offers Natural, Professional, Friendly and Concise tones; changing the tone regenerates from the original passage. Repeating a command while its preview is open brings that preview forward.

Selection capture first uses Accessibility, enabling the accessibility tree for Electron apps such as Slack. If the app does not expose selected text, the helper briefly sends ⌘C and restores the clipboard. A clipboard change must be observed; an unchanged clipboard is never treated as a selection. Replacement checks the original app, selected text, and any available window, field and selection range. A mismatch keeps the preview open with Copy available. Replacement sends ⌘V and never Return into the source app, so it does not submit a Slack message.

## Install Custom Commands

Requires macOS 15+, Apple Silicon, Node 22+ for building, and Xcode Command Line Tools. The installed native commands do not need Node or Raycast running.

```sh
npm ci --ignore-scripts
npm run setup
npm run build:selection
npm run install:selection
```

The installer places **GrammarNazi.app** in `~/Applications/`, registers the two Custom Commands, and enables Custom Commands and their launcher visibility. It preserves existing commands and hotkey identities. Existing Custom Command preferences and a previous installation are backed up under `~/Library/Application Support/GrammarNazi/`. Upgrading the former Grammarly Local app moves its hidden installation into that backup folder.

Restart Tinycast once after installation so 0.9.7-sequoia reloads its Custom Commands. On first use, allow **GrammarNazi** under **System Settings → Privacy & Security → Accessibility**, then return to Slack or your editor, select text and run the command again. The app's preview includes an Accessibility Settings button if permission is missing. To add the app manually with the `+` button, use **⌘⇧G** in the file chooser to open `~/Applications/`.

The resizable preview wraps long words, URLs, and code inside its scroll area. Switch between **Preview** for formatted headings, lists, and emphasis, and **Markdown** for the exact text that Copy and Replace use. Markdown edits retain heading levels, list markers and numbering, indentation, blank lines, emphasis delimiters, links, and code. Only prose is sent for editing; formatting tokens are protected and restored, and malformed model output is rejected. Code-only selections remain unchanged.

Both commands are available in the launcher. Assign global shortcuts through Tinycast's Custom Commands settings. Keep **Load shell environment**, **Needs confirmation** and **Show confirmation** off for these commands. No text argument is required: the native helper reads the selection directly.

For manual registration, `dist/custom-commands.txt` contains the two exact shell commands. `dist/GrammarNazi.app` is also runnable before installation. Keep the project's `models/` folder in place; the app's `Contents/Resources/configuration.json` points to that GGUF file. To move the model, update that path in the source build configuration and rebuild/reinstall the app.

Canceling a preview or changing tone stops the current inference job. Local model processes exit after each request. Temporary input and result files are stored in private directories and removed after inference. Copy intentionally leaves the result on the clipboard; temporary selection copies and paste operations restore the previous clipboard unless another app has changed it. Clipboard managers can observe this temporary traffic. Password fields and Secure Input are refused.

### Native workflow checks

```sh
npm run test:selection
npm run test:selection-models
```

The first command checks shared prompts, Markdown structure preservation, response validation, selection identity changes, cancellation before process launch, and idempotent Custom Command registration. The second also runs plain and Markdown passages through the real model and renders demo and long-text previews to `vendor/selection-*.png`, checking wrapping and scrolling. It requires loopback networking and a graphical macOS session.

After granting Accessibility, check a draft in Slack: select text, run each command, replace it, and use Slack's Undo. Also change the selection or switch apps while generation runs and confirm Replace refuses the changed target. These app-specific checks require real Accessibility access; automated core tests do not establish Slack compatibility.

## Build and local inference

The native app and the two Tinycast Custom Commands are the complete installation. No Raycast extension, React runtime, Ollama, or npm dependencies are required. Node 22+ runs the build and setup scripts; the installed app uses Swift and llama.cpp directly.

Setup downloads the pinned llama.cpp **b11461** Apple Silicon release and Qwen3.5-4B Q4_K_M GGUF weights, verifying downloads with SHA-256. Allow roughly 2.74 GB for the model plus the runtime. Existing verified downloads are reused. Model weights stay in `models/`, outside the app bundle.

`npm run build` produces only `dist/GrammarNazi.app`, the command installer, and manual command instructions. It clears old generated extension files and app bundles first. If you rename or move the project directory, rebuild and reinstall so the app records the model's new absolute path.

Qwen generates corrections and rewrites directly, with thinking disabled. There is no embedding model or retrieval step. Input is limited to 12,000 UTF-16 units. Incomplete output is rejected. Editing quality depends on the model and language.

Inspired by [DigUp's llama.cpp integration](https://github.com/ARahim3/DigUp/blob/main/Sources/LlamaRuntime/LlamaEmbedder.swift), the Swift helper starts an authenticated llama.cpp server on loopback for each request. It terminates and reaps that process after inference, cancellation, or parent exit. No daemon stays running between commands.

Run `npm test` for native core checks, `npm run test:helper` for local HTTP transport and process cleanup checks, and `npm run test:selection-models` for real Qwen edits and preview rendering. The latter two need loopback networking; preview checks also need a graphical macOS session.

## Privacy and implementation

After setup, editing uses only the short-lived local server. Requests pass through private temporary files that are removed after each job. The app does not persist text or editing history. Copy and Replace use the original Markdown source, independent of preview rendering.

The bundle identifier and Custom Command IDs stay stable across the rename to retain macOS settings and shortcuts. They are active identifiers rather than old installations.

Third-party acknowledgements ship in `assets/Acknowledgements.txt`. Models and downloaded runtime files are excluded from Git.
