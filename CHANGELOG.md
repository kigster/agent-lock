# Changelog

## [Unreleased]

### Fixed

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
