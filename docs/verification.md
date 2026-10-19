# Verification & Test Coverage

## Test Suite Summary

SpeedChat is verified through two automated native layers:

1. **Swift Testing Suite (`45/45 passing`)** — `scripts/test.sh`
   - **Standalone OpenRouter → Codex Handoff**: Restores a local `openrouter-…` conversation with either provider selected, creates a real Codex thread before sending, preserves visible history without forwarding private reasoning, persists the replacement ID, and avoids repeating history on subsequent turns. Failed or malformed thread creation preserves history and allows retry. These checks use a fake transport; the installed app and the user's saved chat are not changed by the tests.
   - **Beam Reasoning Continuity**: Replays private reasoning across follow-ups and restarts, keeps it out of visible responses and other providers, and supplies legacy/mixed-model history as quoted context rather than fabricating reasoning or disabling provider validation.
   - **Provider Error Diagnostics**: Retains HTTP status, provider name, nested upstream error messages, and typed error metadata for HTTP and SSE errors; prevents OpenRouter errors from being rewritten as Codex errors.
   - **Model Catalog & Defaults**: Filters low-reasoning-effort OpenAI models (`gpt-6-luna` default when available) and merges configured OpenRouter open-weight models (`deepseek/deepseek-v4.1-flash`, `mistralai/mistral-large-4-0`, `qwen/qwen3.8-flash`, `moonshotai/kimi-k3`, `z-ai/glm-5.3-flashx`, `google/gemma-4-26b-a4b-it`, `deepseek/deepseek-v4-pro-0813`).
   - **OpenRouter Streaming & Web Search**: Verifies native `URLSession` SSE delta streaming, on-demand `web_search` tool invocation triggering `plugins: [{ id: "web", max_results: 5 }]`, citation link formatting, mid-chat switching between OpenAI and OpenRouter with preserved conversation context, and standalone OpenRouter operation when Codex is offline.
   - **Session Lifecycle & Safety**: Tests send/new-chat/model-selection busy gating, early interrupt latching before turn ID acknowledgement, foreign/late event filtering, first-message-derived conversation naming (`thread/name/set`), client tool refusal (`-32601`), unexpected tool item interruption, and plain-text refusal of image generation/view tool attempts.
   - **Markdown, Citations & Math Normalization**: Protects fenced and inline code blocks before normalizing citation markers and LaTeX math to readable Unicode; flushes unclosed streaming links across newlines without stalling.
   - **Runtime & State Isolation**: Confirms `0600` file permissions on `state.json` and `openrouter.json` under `~/Library/Application Support/SpeedChat/`, `0700` private temporary runtime directories, executable symlink resolution, directory override rejection, and environment allowlisting (stripping ambient API keys and `NODE_OPTIONS`).
   - **Framing & Security Policy**: Tests `JSONLFramer` across arbitrary UTF-8 byte chunks and truncated EOF, and `LinkPolicy` validation (allowing only `http`/`https` URLs with a valid host and no credentials or control characters).
   - **Session & Keyboard State Machine**: Verifies `ChatSession` busy gating, `modelsUpdated` hot-reloading, `ChatModel.isOpenRouter` classification, and `KeyboardPolicy` (`↵` send, `⇧↵` newline, `Esc` stop/dismiss, `⌘W` dismiss without interrupting active streams, `⌘N`/`⌃N` new chat, `Page Up`/`Page Down`).
   - **Subprocess & Preferences Integration**: Tests cooperative Codex subprocess close timing, server tool refusal over stdio, symlinked executable discovery, and `Preferences` OpenRouter configuration persistence with `0600` permissions.

2. **Native UI Fixture Smoke** — `scripts/smoke-ui.sh`
   - **New Chat Transcript Reset**: Rebuilds the scroll container whenever a conversation loads. The focused run passed 24 checks, including five resets from a scrolled conversation at 580-point width and replies arriving while hidden. Run `dist/SpeedChat.app/Contents/MacOS/SpeedChat --ui-smoke --new-chat-smoke --smoke-output /tmp/speedchat-new-chat` after building. The full v1.1.4 fixture passed 30/32 checks. Its two provider-error popover checks still failed, matching the limitation reported for v1.1.3; all five new-chat checks passed.
   - Opens error details through fixture-window mouse events, verifies the chat stays visible, and reads back the complete selectable error message from the popover. Saves error-footer and popover screenshots; this does not require desktop accessibility permission.
   - Launches `dist/SpeedChat.app` in fixture mode (`--ui-smoke`) and verifies:
     - Automatic focus of the editable `ComposerTextView` on panel open before backend readiness.
     - Compact draggable header, normal window level, resizability, and all-Spaces/fullscreen behavior flags.
     - Focus-loss dismissal and warm backend reuse on reopen.
     - `Shift + Enter` newline insertion, `Enter` single-request dispatch, busy gating during streaming, `Stop` interrupt dispatch, and post-completion `New Chat`.
     - Pointing-hand cursor configuration (`NSCursor.pointingHand`) and validated URL attachment on rendered prose links.
     - Pixel-based link hover alignment against actual SwiftUI-rendered glyphs after multiple paragraphs, plus single-line, wrapped, and heading links at panel widths of 580 and 790 points. The regression caught TextKit line-height drift and mismatched heading font/padding; it does not synthesize a physical mouse click or open a browser.
     - Native clipboard copy (`NSPasteboard`, preserving/restoring user clipboard contents) and rejection of unsafe file URLs.
     - Non-scrolling Settings window fitting content cleanly and `Edit → Paste` (`⌘V`) menu wiring.

## Live Beam Verification

The native OpenRouter client was exercised with generic diagnostic prompts using a real configured account: a first turn returned `READY.`, a follow-up with preserved reasoning returned `ORCHARD.`, and continuation of the same visible history without old reasoning returned `ORCHARD` via quoted-context migration. The user's existing conversation was not resent for these diagnostics. Restart persistence and provider-switch isolation are covered by automated tests, not a live account restart test.

## Live Sol Transcript Investigation

The reported blank panel was captured in the running installed app even though both user messages and Sol replies were persisted. Two isolated live GPT-6.1-Sol new chats delivered deltas, final messages, and completion events successfully through the native bridge and session. Fixture resets also rendered correctly before the change, so the intermittent trigger is not reproduced deterministically. The fix gives each loaded transcript a fresh scroll container to discard the previous lazy layout and clip position. The user confirmed that both the provider handoff and blank-transcript fixes work in the installed app.

## Scope & Manual Verification Notes

- Ad-hoc code signing (`codesign --sign -`) is used for local personal installation; public binary distribution outside source builds would require Apple Developer ID signing and notarization.
- Physical global hotkey delivery (`⌥Space`), multi-display Spaces/fullscreen transitions, and `SMAppService` Launch-at-Login registration in macOS System Settings require interactive desktop verification.
