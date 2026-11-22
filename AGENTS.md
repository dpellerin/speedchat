## Privacy & Security Invariants
- Never commit or log API keys, tokens, or machine-specific paths.
- Keep OpenRouter credentials and conversation state in `~/Library/Application Support/SpeedChat/` (`0700` directory, `0600` files) and never pass OpenRouter keys into the Codex child environment.

## Repo navigation

Read `docs/agents/repo-guide.md` when locating app entry points, tracing chat requests, or choosing verification checks.

## Agent skills

### Issue tracker

Track issues and specs in GitHub Issues for `dpellerin/speedchat`. See `docs/agents/issue-tracker.md` for issue workflows.

### Triage labels

Use the default triage labels. See `docs/agents/triage-labels.md` when triaging issues.

### Domain docs

SpeedChat uses a single-context layout. See `docs/agents/domain.md` before exploring domain code or proposing changes to terms or decisions.
