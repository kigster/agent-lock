# Changelog

## [Unreleased]

## [0.2.0]

### Added

- An `agent-lock` skill, shipped in the gem under `skills/`, that teaches an
  agent to claim files: naming itself on every call, running `alo` in the
  checkout it writes, and claiming its own files inside an orchestrator's
  lock. `alo skill install [--into DIR] [--force]` copies it into a skills
  directory, and `alo skill path` prints where the bundled copy is.
  `--for claude` installs into `~/.claude/skills`; without `--for` or
  `--into`, `~/.agents/skills` is the default for most other agents.
- `AGENT_LOCK_MUTEX_TIMEOUT`, the seconds a claim waits for the store's mutex.
- `whoami`, which prints the name this session signs locks with, its parent,
  and where each came from.
- A virgin tree now defaults to the Redis backend when one answers on
  `REDIS_URL`, and the file store when none does, rather than always
  defaulting to file. `AGENT_LOCK_BACKEND` still overrides it, and a tree
  that already has a backend recorded stays on it regardless of what Redis
  is doing. Two processes racing to decide the default for the same virgin
  tree are made to agree: the marker recording the choice is claimed with
  `O_CREAT|O_EXCL`, and every process builds from whichever value actually
  lands on disk rather than its own guess. See `README.md#backends`.
- Colorized `--help` and error output via `pastel`, disabled automatically
  when stdout is not a terminal.
- `AGENT_LOCK_TEST_BACKEND`, which runs the whole spec suite against Redis
  instead of the file store. CI now runs the suite once per backend.

### Changed

- The packaged gem no longer includes `.plans/`.
- `redis` and `pastel` are now runtime dependencies of the gem, rather than
  gems you install yourself to opt into the Redis backend: deciding the
  default now means probing for Redis whether or not you asked for it.
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
