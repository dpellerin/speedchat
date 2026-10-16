# Verification & Test Coverage

## Test Suite Summary

SpeedChat is verified through three automated layers:

1. **Backend Unit & Integration Tests (`44/44 passing`)** — `npm --prefix backend test`
   - **Model Catalog & Defaults**: Filters low-reasoning-effort OpenAI models (`gpt-6-luna` default when available) and merges configured OpenRouter open-weight models (`deepseek/deepseek-v4.1-flash`, `mistralai/mistral-large-4-0`, `qwen/qwen3.8-flash`, `moonshotai/kimi-k3`, `z-ai/glm-5.3-flashx`, `google/gemma-4-26b-a4b-it`, `deepseek/deepseek-v4-pro-0813`).
   - **OpenRouter Streaming & Web Search**: Verifies SSE delta streaming, on-demand `web_search` tool invocation triggering `plugins: [{ id: "web", max_results: 5 }]`, citation link formatting, mid-chat switching between OpenAI and OpenRouter with preserved conversation context, and standalone OpenRouter operation when Codex is offline.
   - **Session Lifecycle & Safety**: Tests send/new-chat/model-selection busy gating, early interrupt latching before turn ID acknowledgement, foreign/late event filtering, first-message-derived conversation naming (`thread/name/set`), client tool refusal (`-32601`), unexpected tool item interruption, and plain-text refusal of image generation/view tool attempts.
   - **Markdown, Citations & Math Normalization**: Protects fenced and inline code blocks before normalizing citation markers and LaTeX math to readable Unicode; flushes unclosed streaming links across newlines without stalling.
   - **Runtime & State Isolation**: Confirms `0600` file permissions on `state.json` and `openrouter.json` under `~/Library/Application Support/SpeedChat/`, `0700` private temporary runtime directories, executable symlink resolution, directory override rejection, and environment allowlisting (stripping ambient API keys and `NODE_OPTIONS`).

2. **Native Swift Testing Suite (`15/15 passing`)** — `scripts/swift-test.sh`
   - **Framing & Security Policy**: Tests `JSONLFramer` across arbitrary UTF-8 byte chunks and truncated EOF, and `LinkPolicy` validation (allowing only `http`/`https` URLs with a valid host and no credentials or control characters).
   - **Session & Keyboard State Machine**: Verifies `ChatSession` busy gating, `modelsUpdated` hot-reloading, `ChatModel.isOpenRouter` classification, and `KeyboardPolicy` (`↵` send, `⇧↵` newline, `Esc` stop/dismiss, `⌘W` dismiss without interrupting active streams, `⌘N`/`⌃N` new chat, `Page Up`/`Page Down`).
   - **Process & Preferences Integration**: Tests cooperative subprocess close timing (<1s), fragmented UTF-8 pipe decoding, symlinked executable discovery, and `Preferences` OpenRouter configuration persistence with `0600` permissions.

3. **Native UI Fixture Smoke (`18/18 passing` in Light & Dark Mode)** — `scripts/smoke-ui.sh`
   - Launches `dist/SpeedChat.app` in fixture mode (`--ui-smoke`) and verifies:
     - Automatic focus of the editable `ComposerTextView` on panel open before backend readiness.
     - Compact draggable header, normal window level, resizability, and all-Spaces/fullscreen behavior flags.
     - Focus-loss dismissal and warm bridge reuse on reopen.
     - `Shift + Enter` newline insertion, `Enter` single-request dispatch, busy gating during streaming, `Stop` interrupt dispatch, and post-completion `New Chat`.
     - Pointing-hand cursor configuration (`NSCursor.pointingHand`) and validated URL attachment on rendered prose links.
     - Native clipboard copy (`NSPasteboard`, preserving/restoring user clipboard contents) and rejection of unsafe file URLs.
     - Non-scrolling Settings window fitting content cleanly and `Edit → Paste` (`⌘V`) menu wiring.

4. **Subprocess Lifecycle Smoke (`3/3 passing`)** — `node scripts/smoke-lifecycle.mjs`
   - Verifies that `close` command, `stdin` EOF, and `SIGTERM` cleanly exit the bridge and all child processes with zero orphans.

## Scope & Manual Verification Notes

- Ad-hoc code signing (`codesign --sign -`) is used for local personal installation; public binary distribution outside source builds would require Apple Developer ID signing and notarization.
- Physical global hotkey delivery (`⌥Space`), multi-display Spaces/fullscreen transitions, and `SMAppService` Launch-at-Login registration in macOS System Settings require interactive desktop verification.
