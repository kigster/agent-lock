# Agent::Lock

[![Ruby](https://github.com/kigster/agent-lock/actions/workflows/main.yml/badge.svg)](https://github.com/kigster/agent-lock/actions/workflows/main.yml)

Advisory locks for the several coding agents that end up working in one checkout.

`agent-lock` (or `alo`, for the times you type it twenty times an hour) is a CLI
an agent runs before it writes. It answers one question, "is somebody else
working here", and it gives the same answer from every process in a session,
which turns out to be the hard part.

## The problem

Two agents share a branch and a working tree. Git does not help. There is no
conflict to resolve, the second writer simply wins, and the first one's work is
gone without an error anywhere. Sub-agents make it worse, because a single
session can let several of them loose in one tree at once.

Locks solve this, but only if the holder can be named reliably. That is where
the naive version falls over.

> [!IMPORTANT]
> An agent harness runs every command in a brand new shell. A lock signed with
> `$$` is signed with a different number each time, so the agent that acquired
> a lock can never release it. Identity has to belong to the session, not to
> whichever process is speaking for it right now.

## Installation

```bash
gem install agent-lock
```

Or in a Gemfile:

```ruby
gem "agent-lock"
```

## Quick start

```bash
alo acquire workflow/** "rewriting the installer"   # claim a corner of the tree
alo check   workflow/lib/cli.rb                     # exits 1 if somebody holds it
alo note    workflow/** "installer done, specs red" # write down where you are
alo list                                            # everything held in this repo
alo release-all                                     # at the end of the session
```

A refusal tells you who and what, not just that you lost:

```
$ alo acquire workflow/lib/cli.rb
REFUSED, do not write here
HELD  workflow/**  by luke-backend  since 2026-09-09T21:04:11Z
      intent: rewriting the installer
```

## How it works

### Identity comes from the session

In order of preference:

| Source | When it applies |
| :-- | :-- |
| `AGENT_ID` | A human or a harness named this session on purpose |
| `CLAUDE_SESSION_ID` | Claude Code sets it, and it survives `--resume` |
| Fingerprint | Neither of the above is set |

The fingerprint walks up from the current process until it finds an ancestor
that is not a shell. That is the `claude` or `codex` process driving the
session, or the terminal a person is typing in. Its pid, start time, uid and
hostname are hashed into a name like `claude-1f4c8a02`, which stays the same
for as long as the session lives and differs from anybody else's.

> [!NOTE]
> The start time is in the hash on purpose. Pids get recycled, and a new
> session that lands on a dead one's number should not inherit its locks.

### Locks live inside `.git`

The store is `$(git rev-parse --git-common-dir)/agent-locks`.

| Property | Why it matters |
| :-- | :-- |
| Git cannot track anything in `.git` | No repository needs a `.gitignore` entry |
| `git clean -xdf` cannot reach it | A cleanup does not silently drop every lock |
| Every worktree resolves to the same directory | One store serves the whole repository |
| It is deleted with the checkout | Nothing outlives the repo in your home directory |

Outside a git repository the store falls back to `~/.agent-locks`, keyed by a
digest of the tree.

### A lock is a document, not a flag

```markdown
---
agent_id: luke-backend
scope: workflow/**
status: active
pid: 69232
created_at: 2026-09-09T21:04:11Z
---
rewriting the installer

## Progress
- 2026-09-09T21:14:02Z installer rewritten, specs still red
```

An agent that runs into this learns who holds the scope and what they are
doing, so it can decide whether to wait or to work somewhere else. A human can
read the same file in an editor.

### Scopes are globs

| Scope | Means |
| :-- | :-- |
| `**` | The whole tree |
| `workflow/**` | Everything under `workflow` |
| `workflow` | The same thing. A directory means everything in it |
| `lib/cli.rb` | One file |

Two scopes conflict when either one's fixed part contains the other's. So
`workflow/**` conflicts with `workflow/lib/cli.rb`, and `docs/**` does not
conflict with `workflow/**`.

> [!TIP]
> The rule deliberately refuses more often than it strictly must. Working out
> whether two globs can ever match the same path has answers nobody can
> predict, and the price of guessing wrong is somebody's lost work.

### Sub-agents are a family, not one holder

Ownership and blocking are separate questions, and conflating them is what lets
sibling sub-agents overwrite each other.

| Relationship | May claim an overlapping scope | Appears in `mine`, can be released |
| :-- | :-- | :-- |
| Yourself | Yes, it is already yours | Yes |
| Your parent session | Yes, you work inside its claim | Yes |
| A sub-agent you spawned | No, you handed that scope out | Yes, so cleanup takes them with it |
| A sibling sub-agent | No | No |

Set `AGENT_PARENT_ID` on a sub-agent to the parent's `AGENT_ID`, and the rest
follows.

### A crash does not strand the tree

A lock whose process is gone, or that nobody has touched in
`AGENT_LOCK_STALE_MINUTES` (120 by default), is cleared out of the way. What
happens next depends on whether anything was written down:

| The lock has | What happens to it |
| :-- | :-- |
| No notes | Deleted. There is nothing to come back to |
| Notes | Orphaned. The claim is void, the record survives |

```
$ alo acquire workflow/**
INTERRUPTED WORK on workflow/**, left by luke-backend
  agent-lock resume workflow/**   # take it back, notes and all
  agent-lock break workflow/**    # throw it away and start over
```

> [!WARNING]
> An orphan blocks nobody, but `acquire` will not silently overwrite one,
> because the notes inside it may be the only record of half-finished work.
> Choose `resume` or `break`.

## Commands

| Command | Does | Exit code |
| :-- | :-- | :-- |
| `acquire <scope> [intent]` | Claim a scope | 1 if held or interrupted |
| `release <scope>` | Give it back | 1 if it belongs to somebody else |
| `check <scope>` | Report who holds it | 1 if held by another session |
| `note <scope> <text>` | Record progress inside a lock you hold | 1 if you do not hold it |
| `resume <scope>` | Take back work a crash interrupted | 1 if there is nothing to resume |
| `list` | Every lock in the store | 0 |
| `mine` | What this session holds | 0 |
| `release-all` | Everything this session holds | 0 |
| `break <scope>` | Take a live lock away from its holder | 0 |

Flags:

| Flag | Where | Does |
| :-- | :-- | :-- |
| `--json` | `check`, `list`, `mine` | Machine-readable output |
| `--dir PATH` | Everywhere | Work as if run from `PATH` |
| `--enforce` | `acquire` | Also make the matched files unwritable |
| `--force` | `acquire` | Permit `--enforce` on a very wide scope |

## Configuration

| Variable | Default | Does |
| :-- | :-- | :-- |
| `AGENT_ID` | fingerprint | Name this session yourself |
| `AGENT_PARENT_ID` | none | The session that spawned this one |
| `AGENT_LOCK_DIR` | `.git/agent-locks` | Keep locks somewhere else |
| `AGENT_LOCK_STALE_MINUTES` | `120` | How long an unverifiable lock is trusted |
| `AGENT_LOCK_BACKEND` | `file` | `file` or `redis` |
| `AGENT_LOCK_TTL_SECONDS` | `0` | Redis expiry. `0` means no TTL |
| `REDIS_URL` | `redis://127.0.0.1:6379/0` | Where Redis is |

## Backends

The file store is the default and needs nothing installed. Redis stores the
same documents, and buys two things a filesystem cannot: `SET NX` settles a
race between two machines, and a TTL expires an abandoned lock without anybody
having to reason about liveness.

```bash
AGENT_LOCK_BACKEND=redis alo acquire workflow/**
```

The `redis` gem is not a dependency of this one. It is required only if you ask
for that backend.

> [!CAUTION]
> The backend is never auto-detected. If one agent found a running Redis and
> switched to it while the agent beside it did not, the two would take locks in
> different stores, see nothing of each other, and both report success. That is
> worse than having no lock at all. The first store created in a tree records
> which backend it is, and a mismatch stops the run.

## Freezing files, on macOS

`acquire --enforce` also runs `chflags uchg` on every matched file, which makes
them unwritable by anything, whether it checks for locks or not.

```bash
alo acquire "config/credentials/**" "keys must not move during the migration" --enforce
```

> [!WARNING]
> This is opt-in for three reasons. It is macOS only, since the Linux
> equivalent (`chattr +i`) requires root. It denies the holder too, so it suits
> a freeze rather than a file you are editing. And a session that dies leaves
> the files frozen, at which point `git checkout` and `rm -rf` start failing
> with "Operation not permitted".
>
> Every frozen path is written into the lock, so `release` and `break` thaw
> them without needing the process that froze them to still exist.

## Telling your agents to use it

Put the rule where every agent reads it, such as `CLAUDE.md` or `AGENTS.md`:

```markdown
Several agents may work in this checkout at once. Before creating or editing
files, claim the narrowest scope that covers your writes:

    alo acquire <scope> "<what you are doing>"

If it refuses, work somewhere else. Record progress with `alo note` so an
interrupted session can be picked up. Release with `alo release-all` when you
are done.
```

Advisory locks work because everybody checks. That is why the rule belongs in
the instructions your agents load, and not only in this README.

## Development

```bash
bin/setup
bundle exec rspec       # 61 examples
bundle exec rubocop
```

The library decides and the CLI prints. Every verb is a method on `Manager`
that returns a result and prints nothing, so the whole lifecycle can be tested
without capturing output. `Launcher` takes `argv`, `stdin`, `stdout`, `stderr`
and `kernel` as arguments, and nothing below it calls `puts` or a receiverless
`exit`, which is what lets Aruba run the CLI end to end inside the test process
instead of forking a Ruby per example.

## License

MIT

## Authors

- Konstantin Gredeskoul @kigster
- Claude Code, @claude
