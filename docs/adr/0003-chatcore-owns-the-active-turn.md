---
status: accepted
---

# Give ChatCore ownership of the active turn

Register the active turn from Send acceptance, before provider startup. ChatCore uses a fresh local identity for each execution to accept Stop, reply updates, and the terminal outcome. A Codex Retry can reuse the saved user message or resume the original provider turn, so those identities can outlive a local execution. The bridge preserves Send and Stop order, and each provider handles cancellation for the matching execution.

For Codex, a Stop before binding stays pending until the matching provider turn can be interrupted. A matching terminal result settles the reply. An acknowledgement can bind the turn ID. A verified receipt establishes delivery of the prompt and quoted history, which SpeedChat records even if the reply is stopped. If startup times out without proof, preserve uncertain delivery and reconcile it before resending under [ADR 0001](https://github.com/dpellerin/speedchat/blob/d1c0a1f5cad48de27a8adbe090238d56200f210a/docs/adr/0001-saved-conversation-history.md).

[ADR 0002](0002-keep-openrouter-submissions-on-stop.md) defines local Stop and the saved reply for an OpenRouter turn.

During graceful reconnect or quit, settle any active OpenRouter turn with one snapshot of the submitted message and accepted reply text. Finish the local save attempt before the replacement backend reads saved history or the app exits. Retire the old execution so its late callbacks cannot write to the conversation. Hiding the panel lets the active turn continue.
