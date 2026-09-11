# Plan: Fix Concurrent Agent Locking

Read `spec.md` beside this file first. Branch `kig/fix-concurrent-agent-locking`, worktree `~/github/kigster/agent-lock.worktrees/fix-concurrent-agent-locking`, based on `origin/main` at `5a30e9b`. Baseline: 96 examples, 0 failures; rubocop clean.

## How the work is split

Four work units run in parallel, in one worktree, and **no file is owned by two units**. A unit that needs a change in a file it does not own says so in its final report instead of editing it.

Seams already in place before the fan-out, so no unit waits on another:

- `Record#stale?(minutes)`: active, and untouched (`updated_at`, else `created_at`) for longer than `minutes`.
- `Identity#source` (`:explicit`, `:session`, `:fingerprint`) and `Identity#parent_source` (`:explicit`, `:inferred`, or `nil`).
- `Store::FileSystem#synchronize` and `Store::Redis#synchronize`, yielding with no locking yet.

New interface shared between units:

- `Manager` returns status `:parent_scope` (exit 1, records = `[parent's record]`) when a child asks for exactly its parent's scope. Unit 1 produces it; unit 4 prints it.
- Invalid scopes raise `Agent::Lock::Scope::Invalid < Agent::Lock::Error`. Unit 3 raises it; the launcher already maps `Error` to exit 2.

## Work unit 1: family and liveness

Owns `lib/agent/lock/identity.rb`, `lib/agent/lock/record.rb`, `lib/agent/lock/manager.rb`, `spec/agent/lock/identity_spec.rb`, `spec/agent/lock/manager_spec.rb`.

- [ ] Infer the parent: `AGENT_ID` set, `AGENT_PARENT_ID` unset, id differs from the fingerprint, so the parent is the fingerprint (`parent_source` `:inferred`).
- [ ] `why_not` short-circuits to `:already_mine` only on the caller's **own** overlapping lock. A lock that only the parent holds no longer covers the child; the child records its own, which then blocks its siblings.
- [ ] A child asking for exactly its parent's scope gets `:parent_scope`.
- [ ] `held_by?` is own plus descendants; drop `ancestor_of?`. `blocks?` is unchanged.
- [ ] `expired?`: same host, so reap only if the holder is dead; another host, so expire when untouched past the window, from `updated_at`.
- [ ] Wrap `acquire` (reap, `why_not`, `create`) and `resume` in `store.synchronize { }`. Freezing stays outside the critical section.
- [ ] Specs: siblings under a parent umbrella block each other; a child's `release-all` leaves the parent's lock; a live holder's old lock survives `reap` and reports `stale?`; a dead holder's lock is reaped; a notes-refreshed remote lock does not expire.

Three commits: parent inference; family ownership and claims; liveness-based reaping.

## Work unit 2: store-wide mutex

Owns `lib/agent/lock/store.rb`, `lib/agent/lock/store/file_system.rb`, `lib/agent/lock/store/redis.rb`, `spec/agent/lock/store/redis_spec.rb`, and new `spec/agent/lock/store/file_system_spec.rb`, `spec/agent/lock/concurrency_spec.rb`.

- [ ] `FileSystem#synchronize`: exclusive `flock` on `<store_dir>/.mutex`, created if missing. It must never be listed as a lock.
- [ ] `Redis#synchronize`: `SET <mutex-key> <token> NX PX <ms>`, retried with jittered backoff, raising `Agent::Lock::Error` past a timeout; released with a compare-and-delete Lua script. The mutex key must not match the `all` scan.
- [ ] A multi-process regression spec through `Manager#acquire`: N forked processes claim `lib/**` and N claim `lib/aN.rb` at once; exactly one record survives. Both backends, and Redis examples skip when Redis is unreachable.

One commit per backend.

## Work unit 3: scope validation

Owns `lib/agent/lock/scope.rb`, `lib/agent/lock/tree.rb`, `spec/agent/lock/scope_spec.rb`, and new `spec/agent/lock/tree_spec.rb`.

- [ ] An empty or blank scope raises `Scope::Invalid`. `.`, `*` and `**` still mean the whole tree.
- [ ] A path or glob resolving outside the tree raises `Scope::Invalid`. `Tree#relative` loses its basename fallback.
- [ ] An absolute path or glob inside the tree is relativised (`/abs/tree/lib/**` becomes `lib/**`).

One commit.

## Work unit 4: CLI output

Owns `lib/agent/lock/launcher.rb`, `lib/agent/lock/cli.rb`, `lib/agent/lock/cli/commands/*.rb` (new `whoami.rb` included), `exe/alo`, `exe/agent-lock`, `spec/agent/lock/cli_spec.rb`, `spec/support/aruba.rb`.

- [ ] Hints and the error prefix name the program that was run. The exe files pass `File.basename($PROGRAM_NAME)`; the default is `agent-lock`.
- [ ] `list` counts only active locks as held, shows orphaned ones in their own "Interrupted" section with the `resume`/`break` hint, and tags live locks past the stale window `STALE`. `check` and `mine` tag the same way. `--json` gains `"stale": true|false`.
- [ ] `acquire` prints `:parent_scope` as a refusal that tells the child to claim something narrower.
- [ ] New `alo whoami [--json]`: id, parent, and where each came from.

Commits: program name; orphan and stale reporting; `whoami` and the `:parent_scope` message.

## Work unit 5: integration (orchestrator)

- [ ] Full suite and rubocop, both green.
- [ ] Re-run every repro from `spec.md` against the branch, sub-agents in one worktree included.
- [ ] `sig/agent/lock.rbs`, `README.md` (sub-agent recipe, family table, stale semantics, scope errors, Redis claim, `CLAUDE_SESSION_ID` wording, example count), `CHANGELOG.md`.
- [ ] Open the pull request and verify it contains every commit.

## Rules for every unit

- Claim each file before editing it, as yourself: `AGENT_ID=<unit-name> AGENT_PARENT_ID=claude-2b81adb4 alo acquire <path> "<intent>"`. Every `alo` call carries that prefix. Release with the same prefix and `alo release-all` at the end.
- Test first. Iterate with only your own spec files; the full suite is unit 5's job, because other units' files are mid-edit.
- `bundle exec rubocop <your files>` is clean before you commit.
- Commit only your own paths: `git add <new files>` then `git commit -m "..." -- <your paths>`. If `index.lock` exists, wait a second and retry. Never commit another unit's files, never push, and never touch `README.md`, `CHANGELOG.md` or `sig/`.
