---
status: accepted
---

# Store searchable conversation history locally with stable conversation IDs

SpeedChat keeps [History](../../GLOSSARY.md) in its own local [saved conversations](../../GLOSSARY.md) under `~/Library/Application Support/SpeedChat/` (`0700` directory, `0600` files) rather than pulling in external Codex threads or introducing SQLite (whose WAL/SHM sidecar files complicate strict `0600` file permissions). Only conversations with at least one message are persisted, and legacy single-conversation `state.json` data migrates automatically.

Each saved conversation has a stable local identity independent of its Codex thread ID, so standalone OpenRouter threads, Codex handoffs, and replacement Codex threads under [ADR 0001](0001-saved-conversation-history.md) preserve the same history entry and per-conversation Codex delivery state. Switching conversations renders saved messages immediately—including while offline—and defers Codex thread resume or fallback until the next OpenAI send.

To preserve the single-active-turn model from [ADR 0003](0003-chatcore-owns-the-active-turn.md), History opens only when no turn is active. Retention pruning (default 30 days, configurable in Settings) measures age from each conversation's last message activity rather than view time, and local deletion never touches external Codex threads.
