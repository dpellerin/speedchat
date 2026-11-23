---
status: accepted
---

# Keep OpenRouter submissions when Stop wins

Stop is available as soon as SpeedChat accepts Send. The submitted message stays in the conversation exactly once and can be included as context on a later send. If Stop comes before OpenRouter dispatch, skip the request. If dispatch has begun, cancel the local request.

The first committed outcome settles the turn and returns the panel to Ready once. When Stop wins, keep the reply text accepted up to that point, including text queued for display, and use the same partial reply in the transcript and saved conversation. Discard later updates. A turn stopped before any reply text contains only the submitted message.

If saving the stopped turn fails, keep it visible, return the panel to Ready with a local-save warning, and leave Send available. The warning explains that the turn may be missing after reopening. Reserve OpenRouter Retry for response failures.

[ADR 0001](https://github.com/dpellerin/speedchat/blob/d1c0a1f5cad48de27a8adbe090238d56200f210a/docs/adr/0001-saved-conversation-history.md) governs saved history and Codex delivery. Saving a stopped OpenRouter turn preserves the existing Codex delivery record.
