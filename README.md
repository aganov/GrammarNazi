# Grammarly Local

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

The installer places **Grammarly Local.app** in `~/Library/Application Support/Grammarly Local/`, registers the two Custom Commands, and enables Custom Commands and their launcher visibility. It preserves existing commands and hotkey identities. Existing Custom Command preferences are backed up to `tinycast-custom-commands-backup.json` beside the app before registration.

Restart Tinycast once after installation so 0.9.7-sequoia reloads its Custom Commands. On first use, allow **Grammarly Local** under **System Settings → Privacy & Security → Accessibility**, then return to Slack or your editor, select text and run the command again. The app's preview includes an Accessibility Settings button if permission is missing. To add the app manually with the `+` button, use **⌘⇧G** in the file chooser to open `~/Library/Application Support/Grammarly Local/`.

Both commands are available in the launcher. Assign global shortcuts through Tinycast's Custom Commands settings. Keep **Load shell environment**, **Needs confirmation** and **Show confirmation** off for these commands. No text argument is required: the native helper reads the selection directly.

For manual registration, `dist/custom-commands.txt` contains the two exact shell commands. `dist/Grammarly Local.app` is also runnable before installation. Keep the project's `models/` folder in place; the app's `Contents/Resources/configuration.json` points to that GGUF file. To move the model, update that path in the source build configuration and rebuild/reinstall the app.

Canceling a preview or changing tone stops the current inference job. Local model processes exit after each request. Temporary input and result files are stored in private directories and removed after inference. Copy intentionally leaves the result on the clipboard; temporary selection copies and paste operations restore the previous clipboard unless another app has changed it. Clipboard managers can observe this temporary traffic. Password fields and Secure Input are refused.

### Native workflow checks

```sh
npm run test:selection
npm run test:selection-models
```

The first command checks shared prompts, response validation, selection identity changes, cancellation before process launch, and idempotent Custom Command registration. The second also runs the real model through the native inference job and renders a demo preview to `vendor/selection-preview.png`. It requires loopback networking and a graphical macOS session.

After granting Accessibility, check a draft in Slack: select text, run each command, replace it, and use Slack's Undo. Also change the selection or switch apps while generation runs and confirm Replace refuses the changed target. These app-specific checks require real Accessibility access; automated core tests do not establish Slack compatibility.

## Raycast extension interface

The project also retains its Raycast-compatible extension interface. Its existing controls and installation instructions are below.

Qwen3.5-4B Q4_K_M generates corrections and rewrites directly, with thinking disabled. There is no embedding model or retrieval step. The model unloads after each request. The prompt preserves the input language; editing quality depends on the model and language.

Inspired by [DigUp's llama.cpp integration](https://github.com/ARahim3/DigUp/blob/main/Sources/LlamaRuntime/LlamaEmbedder.swift). DigUp links llama.cpp directly; this extension uses a small Swift helper that starts a temporary, authenticated llama.cpp server on loopback for each request. It terminates and reaps the server after inference, on termination signals, or if the helper's parent exits. No daemon stays running between commands.

## Build and install

Requires macOS 15+, Apple Silicon, Node 22+ and Xcode Command Line Tools (`xcode-select --install`). Allow roughly 2.74 GB for the model, plus the runtime and build dependencies. More memory and a faster GPU improve performance.

```sh
npm ci --ignore-scripts
npm run setup
npm run build
```

Setup downloads the pinned llama.cpp **b11461** Apple Silicon release and a pinned Qwen GGUF file from Unsloth. Downloads are verified with SHA-256 before installation. Existing verified models are reused. `npm run setup -- --runtime-only` downloads only the runtime. Model weights stay in `models/`, separate from the extension bundle; keep that folder after installation.

1. In Tinycast, enable **Settings → Extensions**.
2. Choose **Install → Add from folder** and select this project's **dist/** folder.
3. In the extension preferences, choose this project's **models/** folder as **Models Folder**.
4. Grant Tinycast Accessibility permission to read selections and paste results.

The dist folder contains `package.json`, both CommonJS commands, the native helper, llama.cpp's runtime files and the icon. Runtime dependencies are supplied by Tinycast. This project builds directly with esbuild, so it does not need Raycast installed. The same dist layout and Raycast APIs can also be used with Raycast on macOS, though native Raycast execution has not been tested.

## Use

Select a passage in your app and launch **Fix Grammar** or **Rewrite**. One screen keeps your text in the top input, a rewrite tone dropdown on the right, the result above the two commands. Input stays visible during generation and after errors. Select either command and press Return to run it. After generation the result is selected; press Return to paste it or use **Copy Result**. Paste replaces the selection if it is still selected in the target app.

Without a selection, type directly in the top input or choose **Use Clipboard Text** (⌘⇧V). For paragraphs, use **Edit Multiline Text** (⌘E), then **Use Text** to return to the same screen. Text supplied as a command argument or fallback text takes priority over the selection. Clipboard text is read only on request.

**Fix Grammar** corrects grammar, spelling and punctuation while preserving wording and voice. **Rewrite** improves clarity and flow; choose a natural, professional, friendly or concise tone in the top dropdown. **Try Again** (⌘R) regenerates a result. **View Full Result** (⌘O) shows long results with the original text. Editing the input or tone clears an outdated result; late responses cannot replace a newer draft. Neither command pastes automatically.

You may select another instruction-tuned GGUF using **Generation Model**. Input is limited to 12,000 characters; model context limits may require a shorter passage. Incomplete model output is rejected rather than presented as a complete result.

## Validation

```sh
npm test
npm run test:helper
npm run test:tinycast
```

Tests cover input validation, distinct editing prompts, formatting, incomplete responses, helper HTTP transport and cleanup, and rendering/interaction using the installed Tinycast runtime. Helper tests use a local mock server and do not require downloaded model weights. These checks do not measure editing quality; that requires running the real models.

Run `npm run test:models` after setup to check actual grammar corrections, rewriting, preservation of numbers and unchanged correct text. On the development MacBook Pro (M1 Pro, 16 GB), the first short edit took about 21 seconds, and subsequent short edits took about 2 seconds including startup and shutdown. These are smoke-test timings, not a throughput benchmark; longer passages take longer.

## Privacy and implementation

After setup, commands make only loopback requests to their own short-lived local server. Text is passed through a private temporary JSON file, removed after each request, rather than through process arguments. The extension does not persist text or editing history. Tinycast's normal clipboard behavior applies to copy and paste.

Sources: [Qwen model documentation](https://huggingface.co/Qwen/Qwen3.5-4B), [GGUF weights](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), [llama.cpp server API](https://github.com/ggml-org/llama.cpp/blob/b11461/tools/server/README.md), [Tinycast extension installation](https://tinycast.dev/docs/extensions/installing/).

Third-party acknowledgements ship in `assets/Acknowledgements.txt`. Models and downloaded runtime files are excluded from Git.
