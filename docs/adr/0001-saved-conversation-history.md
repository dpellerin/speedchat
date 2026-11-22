---
status: accepted
---

# Use saved messages as the primary conversation history

SpeedChat's [saved conversation](../../GLOSSARY.md) is the primary history. A Codex thread can omit OpenRouter replies or contain several earlier messages quoted as a single prompt, so message count can't establish which history is more complete. Preserve saved messages and import a missing Codex message only when SpeedChat can verify where it belongs in the conversation.

Reopen the saved conversation if Codex resume fails. On the next OpenAI send, retry the original Codex thread when it may still be usable. Create a replacement only when Codex confirms the original is unusable, then quote the saved message text as context for that send. New Chat is the explicit reset.

Save enough about an unconfirmed OpenAI send to check delivery after restart. Check Codex before retrying the turn. If Codex confirms it recorded the prompt and quoted history, persist that delivery even if the reply fails or is stopped. A confirmed rejection allows a normal retry. If delivery is still uncertain, show that status and offer an explicit resend of the same turn while keeping one user message in the transcript.
