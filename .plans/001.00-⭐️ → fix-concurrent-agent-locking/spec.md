# Fix Concurrent Agent Locking

## Problem

`agent-lock` 0.2.0 is meant to let several agents, including several sub-agents of one session, work in one checkout without overwriting each other. Real-world testing on 2026-09-09 and 2026-09-11 showed it does not deliver that:

1. **Sub-agents are indistinguishable from their parent.** Claude Code runs sub-agents inside the parent's `claude` process, and sets no per-agent environment variable (`CLAUDE_SESSION_ID` is not set either). The fingerprint walks up to that shared process, so parent and every sub-agent resolve to the same id (observed: both `claude-2b81adb4`). They can never block each other.
2. **A child's claim inside its parent's lock records nothing.** `Manager#why_not` returns `:already_mine` when the only overlapping lock is the parent's. Two siblings then both "acquire" the same file with exit 0. This is the documented orchestration pattern (parent claims, then fans out).
3. **A child's `release-all` drops its parent's locks.** `Record#held_by?` counts the parent's locks as the child's own.
4. **Overlapping scopes race.** `why_not` scans, then `create` writes; `O_EXCL` / `SET NX` only guard an identical scope. 10 parallel acquires of `lib/**` and `lib/aN.rb` left 9 to 11 overlapping locks, on both the file and Redis backends.
5. **Live agents lose their locks after 120 minutes.** `Record#expired?` reaps any lock older than the stale window even when its holder is provably alive, measured from `created_at`, so notes do not refresh it. Without notes the lock is deleted outright.
6. **Bad scopes succeed silently.** An empty scope means `**`. `/etc/passwd` becomes the tree-local `passwd`; `../x/**` is stored verbatim.
7. **Output misleads.** `list` counts interrupted (orphaned) locks as held and never flags stale ones; hints and error prefixes say `agent-lock` even when run as `alock`.

## Goal

Several agents, and several sub-agents of one session sharing one worktree, can each claim disjoint parts of the tree and are reliably refused when they overlap, under real concurrency, for as long as they are alive.

## Decisions

- **Sub-agent identity is declared, parent is inferred.** Nothing in a sub-agent's process tree differs from its parent's, so the gem cannot detect one. A sub-agent runs `AGENT_ID=<its-name> alock ...` on every call. When `AGENT_ID` is set, `AGENT_PARENT_ID` is not, and the id differs from the session fingerprint, the parent defaults to the fingerprint, which is the orchestrator's identity. New `alock whoami` prints the resolved id, parent and where each came from.
- **A child claiming its parent's exact scope is refused** (exit 1, telling it to claim something narrower). Records are keyed by tree and scope, so the child cannot hold a second record on the identical scope, and refusing fails closed.
- **Ownership (`mine`, `release`, `release-all`, `note`) is own plus descendants, never ancestors.**
- **A live holder's lock is never reaped.** Same-host locks are reaped only when the holder is provably dead. Only locks whose holder cannot be checked (another host) expire by time, measured from `updated_at`, so notes act as a heartbeat. Live locks older than the stale window are reported `STALE`, and breaking one stays a human-announced `break`.
- **Scan and create happen under one store-wide mutex.** File store: `flock` on `<store>/.mutex`. Redis: `SET NX PX` on a per-namespace mutex key with a random token, released by compare-and-delete in Lua, retried with backoff, and bounded by a timeout that raises.
- **Invalid scopes raise** `Agent::Lock::Error` (exit 2): empty, or resolving outside the tree. Absolute paths inside the tree are relativised, globs included.
- **Messages name the program that was run** (`alock` or `agent-lock`).

## Out of scope

- `~/.agents/bin/agent-lock` (the old shell script) shadows the gem's `agent-lock` on PATH. That lives in the dot-agents repository.
- `alock help <command>` (dry-cli does not support it; `alock <command> --help` works).
- Version bump and release.
