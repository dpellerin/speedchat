# SpeedChat

A fast, keyboard-summoned native macOS quick-chat panel built with SwiftUI and AppKit.

Summon a lightweight, distraction-free conversation window from anywhere with **Option + Space**, chat with **OpenAI** (via your existing local Codex CLI login) and **open-weight models on OpenRouter** from a single unified model picker, and dismiss right back to your work.

Zero external dependencies, zero external Swift packages, and no Electron/WebView or Node.js wrapper.

---

## Highlights

- **Unified Model Picker (OpenAI + OpenRouter)**
  - **OpenAI**: Uses your local `codex login` session (`gpt-6-luna` default when available) with hosted live web search—no OpenAI API key required.
  - **OpenRouter**: Optionally add an OpenRouter API key in **Settings (`⌘,`)** to chat with fast, personable open-weight models alongside OpenAI, or run standalone with OpenRouter alone.
  - **Curated Open-Weight Defaults**: Ships with **DeepSeek V4.1 Flash**, **Mistral Large 4**, **Qwen 3.8 Flash**, **Kimi K3**, **GLM 5.3 FlashX**, **Gemma 4 26B A4B**, and **DeepSeek V4 Pro**—customizable directly in Settings (`slug` or `slug | Display Name`).
  - **Seamless Mid-Chat Switching**: Switch between OpenAI and OpenRouter models inside the same conversation without losing context.
  - **Beam Follow-Ups**: Preserves Beam's required reasoning metadata privately across turns and app restarts. Older replies without that metadata are supplied as quoted conversation context; reasoning is never shown in chat or forwarded to other models.
  - **Readable Errors**: Failed requests expose a **Details** popover with the HTTP status, available provider diagnostics, selectable text, and **Copy**.
- **On-Demand Web Search**
  - Hosted live web search on OpenAI models and on-demand OpenRouter web search (`plugins: [{ id: "web" }]`) triggered only when current information is needed, with inline Markdown source citations.
- **Native macOS Experience**
  - Compact, draggable, resizable `NSPanel` with semantic light/dark appearance (clean white chat surface in light mode, native contrast in dark mode).
  - Joins all Spaces and works over fullscreen apps; automatically hides when it loses focus while keeping your draft, conversation, and warm backend ready.
  - Native selectable prose, code blocks with one-click copy, and readable Unicode math normalization.

---

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| **⌥ Space** *(configurable)* | Summon or hide the SpeedChat panel from anywhere |
| **↵ (Enter)** | Send message |
| **⇧↵ (Shift + Enter)** | Insert newline in composer |
| **⌘N** / **⌃N** | Start a new chat (keeps selected model) |
| **Esc** | Stop active streaming response, or hide the panel when idle |
| **⌘W** | Hide the panel without interrupting an active response or clearing draft |
| **⌘,** | Open Settings |
| **⌘Q** | Quit SpeedChat |
| **Page Up / Page Down** | Scroll transcript |

---

## Prerequisites

- **macOS 14 (Sonoma)** or newer (Apple Silicon / `arm64`).
- **At least one model provider**:
  - **OpenAI via Codex CLI**: Install the [Codex CLI](https://developers.openai.com/codex/app-server) and sign in once with `codex login` in Terminal, **and/or**
  - **OpenRouter**: An API key from [openrouter.ai](https://openrouter.ai), configured in **SpeedChat Settings (`⌘,`)** (works standalone with zero CLI dependencies).

When using OpenAI via Codex, the app automatically discovers `codex` (and `node` if your `codex` shim uses it) across `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, common version-manager paths (`~/.volta/bin`, `~/.asdf/shims`, `~/.local/share/mise/shims`, `~/.fnm/current/bin`, `~/Library/pnpm`), and `~/.hermes/tools` without sourcing shell startup files.

---

## Download & Install

### Option 1: Download Prebuilt App (GitHub Releases)

1. Download **`SpeedChat-macos-arm64.zip`** from the latest [GitHub Release](../../releases), unzip it, and drag **`SpeedChat.app`** into **`/Applications`**.
2. Because the prebuilt app is ad-hoc signed rather than notarized with a paid Apple Developer ID, strip macOS's browser quarantine flag once in Terminal before first launch:

```sh
xattr -dr com.apple.quarantine /Applications/SpeedChat.app
open /Applications/SpeedChat.app
```

### Option 2: Build & Install from Source (No Gatekeeper Prompt)

Clone the repository, run the Swift verification suite, build the signed `.app` bundle locally, and install to `/Applications`:

```sh
scripts/test.sh
scripts/build-app.sh
scripts/smoke-ui.sh
scripts/install-app.sh
```

- `scripts/build-app.sh` compiles the release Swift executable, renders the `.icns` app icon natively with AppKit, bundles resources into `dist/SpeedChat.app`, and applies an ad-hoc code signature for local personal use.
- `scripts/install-app.sh` validates the bundle signature and identifier (`local.speedchat`), stages the update, gracefully quits any running instance, retains a rollback copy (`SpeedChat.previous.app`), installs `/Applications/SpeedChat.app`, and launches it without altering your saved chats, preferences, or login items.
- `scripts/package-release.sh` builds and packages `dist/SpeedChat-macos-arm64.zip` (with SHA-256 checksum) for attaching to a GitHub Release.

To run directly from the checkout without installing to `/Applications`:

```sh
open dist/SpeedChat.app
```

---

## Configuring OpenRouter

1. Open SpeedChat (**⌥Space**) and press **⌘,** (or click the menu-bar bubble icon → **Settings…**, or choose **Configure OpenRouter in Settings…** from the header model menu).
2. Paste your OpenRouter API key (`sk-or-v1-...`) using **⌘V** or the **Paste** button.
3. Customize the open-source model list if desired:
   - Add any OpenRouter model slug (`provider/model-name` or `provider/model-name | Custom Name`).
   - Remove models you don't use with **×**, or click **Reset Defaults** at any time.
4. Pick any model under the **OpenAI** or **OpenRouter** section of the header menu.

---

## Privacy & Security Boundary

- **Chat & Web Search Scope Only**: Local file tools, shell execution, MCP servers, plugins, skills, browser automation, and code execution are explicitly disabled. Codex runs in an isolated empty temporary directory (`0700`) with a `read-only` sandbox and `approvalPolicy: "never"`.
- **Credential Isolation**:
  - Conversation state and OpenRouter configuration are stored in `~/Library/Application Support/SpeedChat/` (`state.json` and `openrouter.json`) with directory mode `0700` and file mode `0600`.
  - Subprocess environments are strictly allowlisted—ambient API keys, `NODE_OPTIONS`, and OpenRouter credentials are never inherited by the Codex child process.
- **Safe Rendering & Links**: Assistant replies render as native SwiftUI text/attributed strings (never HTML/WebView). All clicked links are validated at the native boundary (`LinkPolicy`), permitting only well-formed `http`/`https` URLs without embedded credentials or control characters. Clipboard actions use `NSPasteboard` directly.

To remove local state after quitting:

```sh
rm -rf "$HOME/Library/Application Support/SpeedChat"
```

---

## Testing & Verification

```sh
# Run the full Swift Testing suite (ChatCore + NativeBridge)
scripts/test.sh

# Run the native UI fixture smoke test (generates docs/ui-smoke/report.json)
scripts/smoke-ui.sh
```

See [docs/verification.md](docs/verification.md) for detailed test coverage and verification notes.

---

## Attribution & License

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party software notices.

Licensed under the [MIT License](LICENSE). Copyright (c) 2026 Dana Pellerin.
