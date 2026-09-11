# Changelog

## [Unreleased]

### Added

- `AGENT_LOCK_MUTEX_TIMEOUT`, the seconds a claim waits for the store's mutex.
- `whoami`, which prints the name this session signs locks with, its parent,
  and where each came from.

### Changed

- A sub-agent that sets `AGENT_ID` but not `AGENT_PARENT_ID` takes its
  session's own name as its parent: `CLAUDE_SESSION_ID` if set, else the
  fingerprint. Claude Code runs sub-agents inside the parent's own process,
  so without this every sub-agent signed locks as the parent and none could
  block another.
- Ownership no longer runs upwards. `mine`, `release`, `release-all` and
  `note` cover your own locks and your sub-agents', never your parent's, so a
  sub-agent finishing up no longer releases the orchestrator's claim.
- A sub-agent asking for exactly its parent's scope is refused with exit 1 and
  told to claim something narrower.
- A scope that is empty, or that resolves outside the tree, is refused with
  exit 2. An empty scope used to mean the whole tree, and `/etc/passwd` used
  to become a lock on the tree-local file `passwd`. Absolute paths inside the
  tree, globs included, are made relative.
- `list` counts only live locks as held, lists interrupted ones separately,
  and tags a live lock past the stale window `STALE`, as do `check` and
  `mine`. `--json` carries `stale`.
- Hints and error messages name the program that was run, `alo` or
  `agent-lock`.
- `whoami` without `AGENT_ID` warns that every sub-agent of the session shares
  that name.

### Fixed

- A sub-agent claiming inside its parent's lock was told `ALREADY YOURS` and
  nothing was recorded, so two siblings could both claim the same file. The
  sub-agent now gets a lock of its own, which blocks its siblings.
- Claims on overlapping scopes with different names raced: the conflict scan
  and the write were separate steps, and `O_EXCL` or `SET NX` only guard an
  identical scope. Ten parallel claims of `lib/**` and `lib/aN.rb` left up to
  eleven overlapping locks. Every claim now scans and writes under one
  store-wide mutex: `flock` on the file store, a leased `SET NX PX` key
  released by compare-and-delete on Redis.
- Holding one file and asking for a wider scope answered `ALREADY YOURS` and
  wrote nothing, so the rest of the wider scope stayed open. Only a lock that
  contains the requested scope counts as already yours now.
- A live holder's lock was reaped once it was older than the stale window,
  measured from when it was taken, so an agent working for more than two
  hours lost its lock while still writing. A lock on this machine is now
  cleared only when its holder has exited; one from another machine expires
  when untouched past the window, and `note` counts as a touch.
- The `resume` and `break` hints printed before the listing they belong to
  whenever stdout and stderr went down one pipe, which is how an agent harness
  reads them. Stdout is flushed before a hint is written.
- A scope starting with a dot, such as `.plans/**` or `.github/**`, produced a
  lock file whose name also started with one, and the file store's `Dir.glob`
  skipped it. The lock was written and then enumerated nowhere, so `list`,
  `mine` and `check` reported it absent and a second session was free to
  acquire an overlapping scope. Both agents were told they held it.

## [0.1.0]

First release.

- `acquire`, `release`, `check`, `list`, `mine`, `release-all`, `break`, plus
  `note` and `resume` for work a crash interrupted.
- Session identity: `AGENT_ID`, else `CLAUDE_SESSION_ID`, else a fingerprint of
  the first ancestor process that is not a shell, so a lock survives the fresh
  shell an agent harness starts for every command.
- Locks live in `.git/agent-locks`, one store per repository, shared by every
  worktree and untrackable by git.
- Glob scopes, and a conflict rule that refuses rather than guesses.
- Sub-agents work inside a parent's claim; siblings block each other.
- Stale locks are reaped by liveness, and orphaned rather than deleted when
  they carry notes.
- Optional Redis backend, chosen explicitly and recorded per tree.
- Optional `--enforce` freeze via `chflags uchg` on macOS.
