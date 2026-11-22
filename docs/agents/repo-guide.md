# SpeedChat repo guide

Use the [glossary](../../GLOSSARY.md) for conversation and provider terms.

## Entry points

| Change | Start here |
| --- | --- |
| App launch, panel visibility, shortcuts, menus | [Entry.swift](../../Sources/SpeedChat/Entry.swift) starts AppKit. [AppDelegate.swift](../../Sources/SpeedChat/AppDelegate.swift) owns the panel and wires [HotKey.swift](../../Sources/SpeedChat/HotKey.swift) and `KeyboardPolicy`. |
| Composer, transcript, model picker, error details | [PanelView.swift](../../Sources/SpeedChat/PanelView.swift) and [Composer.swift](../../Sources/SpeedChat/Composer.swift). [ChatStore.swift](../../Sources/SpeedChat/ChatStore.swift) holds the draft and drives [ChatSession](../../Sources/ChatCore/Session.swift), the UI state machine. |
| Model availability and settings | [Settings.swift](../../Sources/SpeedChat/Settings.swift) saves preferences and triggers reconnect or config reload. [Runtime.swift](../../Sources/ChatCore/Runtime.swift) resolves the Codex executable. [ChatClient.swift](../../Sources/ChatCore/ChatClient.swift) builds the model catalog. |
| Conversation resume, provider switches, and saved history | `ChatClient.connect`, `newChat`, and `send` in [ChatClient.swift](../../Sources/ChatCore/ChatClient.swift). [StateStore.swift](../../Sources/ChatCore/StateStore.swift) handles local persistence and reads Codex turn history. |

## Request flow

1. **Submit.** `ChatStore.send` calls `ChatSession.beginSend` to check readiness and reject a blank draft. The session adds the user message to the transcript and enters the sending phase. The store dispatches to the in-process [BridgeProcess](../../Sources/SpeedChat/BridgeProcess.swift), which calls `ChatClient.send`.
2. **Route.** `ChatClient` snapshots the selected model for the turn. OpenAI uses `turn/start` through [CodexProtocol.swift](../../Sources/ChatCore/CodexProtocol.swift) and its Codex app-server subprocess. If the conversation started in standalone OpenRouter, the first OpenAI send creates a Codex thread. `ChatClient` quotes any prior messages that thread has yet to receive. [OpenRouter.swift](../../Sources/ChatCore/OpenRouter.swift) sends conversation history over HTTP, reads server-sent events, and requests a search-enabled pass when the model calls for web search.
3. **Render.** `ChatClient` uses [Render.swift](../../Sources/ChatCore/Render.swift) to resolve citations and normalize assistant text. The bridge batches text deltas and emits `BridgeEvent`s. `ChatStore` applies them to `ChatSession` on the main actor, where a final message replaces its streamed text and completion or error events update the status. For a blank or stale transcript after **New Chat**, trace the `ready` event through `ChatSession.transcriptID` to the scroll container in `PanelView`.
4. **Stop.** The Stop button and Escape during a response dispatch `interrupt`. `ChatClient` cancels the OpenRouter stream or sends `turn/interrupt` to Codex. Command-W hides the panel while the turn continues.

Check the [privacy boundary](../../README.md#privacy--security-boundary) when changing runtime scope, credentials, persistence, or link handling. Keep Beam reasoning out of transcripts and preserve it only for Beam follow-ups.

## Verification

- **Behavior and integration.** Run `scripts/test.sh`. Start with [ChatCoreTests](../../Tests/ChatCoreTests) for state, routing, history, streaming, and rendering. Use [NativeBridgeTests](../../Tests/NativeBridgeTests) for subprocess and settings behavior. Provider tests use fake Codex transport and stubbed HTTP responses.
- **Native panel.** For UI changes, run `scripts/build-app.sh` followed by `scripts/smoke-ui.sh`. Check `docs/ui-smoke/report.json` for the relevant assertions and inspect the screenshots when layout changes. [UISmoke.swift](../../Sources/SpeedChat/UISmoke.swift) supplies the fixture events and assertions.
- **Desktop and live providers.** Use the scope notes in [Verification & Test Coverage](../verification.md) for the physical hotkey, Spaces and fullscreen transitions, Launch at Login, and checks that require provider credentials.
