# Changelog

## [4.0.0] - 2026-11-26

### Added

- `Agent::Lock::Facade`: every command as a Ruby method, run in-process. `Agent::Lock.local` (file store), `Agent::Lock.distributed` (Redis, or `RedisUnavailableError`) and `Agent::Lock.facade` (Redis, else the file store). Thread-safe. See `README.md#ruby-api`.
- `Agent::Lock::Refused` and `Agent::Lock::RedisUnavailableError`.
- `Facade#acquire` takes a block: it yields the result, returns the block's value, and releases afterwards, even when the block raises, `break`s or `throw`s. Only a lock this call took is released, so a nested block on a scope you already hold keeps the outer lock. A refused release does not replace the block's own exception.
- `Facade.new(async: true)` and `Agent::Lock.facade(async: true)` add `#async`, which runs any lock method on concurrent-ruby's I/O pool and returns a `Concurrent::Promises::Future`. Arguments, keywords and blocks pass through as on a direct call. One facade's async calls run one at a time, in the order they were made. concurrent-ruby is not a direct dependency (`dry-cli-ui` currently installs it): add it to your Gemfile to rely on this; if it is missing, `async: true` raises `LoadError` naming the gem.
- `holder:` on `Facade.new` and `Agent::Lock.facade`. `:process`, the default, ties a lock's liveness to the Ruby process holding the facade, so a host that crashes has its locks reaped; `:session` keeps `alock`'s first-non-shell-ancestor rule. Only liveness changes: the holder id and the inferred parent still come from the session, so a script an agent runs is the same holder as that agent's `alock`.
- `alock --locking-strategy redis|filesystem` (`-s`) and `alock --redis-url URL` (`-u`), on every command that reads or writes locks. The caller names the store instead of leaving it to `AGENT_LOCK_BACKEND` or to whichever backend answers first, so an agent started by a dispatcher uses the dispatcher's store. `--redis-url` implies the Redis strategy and uses that one Redis with no fallback: a URL nobody answers on exits 2.
- `AGENT_LOCK_REDIS_URL`: `--redis-url` from the environment, for a dispatcher to export to its agents. The facade reads it before `REDIS_URL`.
- `Agent::Lock.distributed(redis_url:)`, memoized per URL.
- `session_name:` on `Facade.new`, `Agent::Lock.facade` and every lock method. It names the session (a plan id, say) in place of `CLAUDE_SESSION_ID` and the fingerprint, and ties its locks to no process: they survive a host's restarts, a restarted host that gives the same name holds them still, and they lapse when untouched for `stale_minutes`.
- `alock -h` opens with a boxed title and the version, and links to the README's Ruby API section.
- A lefthook pre-commit config (rubocop, the staged specs, gitleaks) and a gitleaks config.

### Changed

- **Breaking:** `alock acquire --force` is now `--allow-wide`, named for what it permits: `--enforce` freezing more than 500 files. The refusal says so.
- **Breaking:** `alock skills install --force` (`-f`) is now `--overwrite`, and `--into` loses its `-o` short flag, which every CLI here reserves for `--output`.
- `--dir` is offered only by commands that read a checkout's locks. `version`, `whoami` and `skills` no longer list a flag that did nothing.
- Every command's help is rewritten: one-line descriptions that fit the command list, examples for `break`, `resume` and `mine`, and a top-level help that covers identity, backends and exit codes.
- `alock completion --help` shows each install example once; the zsh one no longer names `_alo`.
- `rake doc` builds the YARD site from `.yardopts` into the git-ignored `doc/` and opens `doc/index.html`. Every class, method, constant and attribute is documented.
- The gemspec and README no longer describe the gem as part of agentilda.
- **Breaking (Ruby):** `Manager#acquire(force:)` is now `wide:`, and `Skill#install(force:)` is now `overwrite:`, matching the CLI flags.
- The coverage badge in `docs/badges/` is rewritten only under `COVERAGE=true` (`just test-coverage`), so a plain `rspec` run leaves the checkout clean.

### Fixed

- `alock` exits 2 with an `ERROR:` line on any error it did not expect. It used to print nothing and exit 0, so an `acquire` that died on a malformed `REDIS_URL` looked like a lock taken.
- `AGENT_LOCK_BACKEND=redis` with no Redis answering no longer claims a virgin tree for Redis before failing.

- Concurrent `note` calls on one lock no longer lose notes: `note`, `release`, `break`, `release-all`, `Manager#reap` and the reaping before `check`, `list` and `mine` now run inside the store mutex, as `acquire` and `resume` already did.
- `acquire --enforce` no longer overwrites the lock with the record it read before freezing. The write-back re-reads the lock under the store mutex, so a note written during the freeze is kept, a lock broken during the freeze stays broken, and another agent's lock taken in that window is neither replaced nor, on a freeze refused as too broad, deleted. A claim lost during the freeze is answered as `:held`, with the files thawed.
- A lock whose record names no pid is trusted for the stale window, like one held on another host, instead of being reaped at once as a dead holder's.
- A backend marker that exists but cannot be read raises `Store::Mismatch` naming the read error, instead of being reported as empty.
- The file store no longer raises `Errno::ENOENT` when several threads in one process rewrite the same lock (reaping, noting): each write gets its own temp file instead of one per process.
- A facade is bound by the checkout's backend marker like `alock`: it claims a new checkout for its backend and raises `Store::Mismatch` in one claimed for the other, so a facade and the CLI never take one scope in two stores.
- The backend marker is written to a temp file and hard-linked into place, so a process that loses the race for a new checkout never reads it empty. A marker that stays empty raises `Store::Mismatch` instead of letting each caller pick its own backend.
- A facade's Redis client uses the gem's default timeouts; the 0.2s timeout applies only to the connection probe.
- A fingerprint identity no longer contains spaces when the session's process has retitled itself (macOS reports a Claude Code background job as `claude bg-spare`). Only the first word is kept, so the holder id changes for such sessions. Before upgrading, release the locks such a session holds (`alock release-all`), or clear them afterwards with `alock break <path>`: the new id does not match the old one, so they read as another agent's.

### Removed

- `sig/agent/lock.rbs`, an empty RBS stub. Types are declared in YARD.
- The `just update-workflow` recipe, which ran `tilda`. `just lint` now runs rubocop instead of the absent standardrb.

## [3.1.0] - 2026-11-23

This release makes `agent-lock` a distributed lock. Until 3.0.0 a lock was named after the checkout's absolute path, so even with every machine pointed at one Redis, `/Users/a/repo` and `/home/b/repo` were two unrelated namespaces: each machine saw only its own locks, and two agents on two hosts could both claim `lib/billing/**` on `main` and both be told they won. A lock now names the repository and branch, which every clone of a repository agrees on wherever it sits. Pointed at one `REDIS_URL`, every machine reads and writes the same locks under the same store-wide mutex, so a claim on one host is refused on another. See `README.md#one-repository-many-machines`.

### Changed

- **Breaking for Redis users:** locks are keyed by the repository and branch, not the checkout's absolute path. The Redis namespace is now `agent-lock:<repository digest>` and its mutex `agent-lock-mutex:<repository digest>`, where the repository is the normalized `origin` URL (`git@github.com:a/b.git` and `https://github.com/a/b` agree), else the root commit, else the path outside git. Two machines on one Redis, or two clones on one machine, now block each other on overlapping scopes of the same branch, and checkouts on different branches (worktrees, typically) still do not. Locks taken by an earlier version under the old path-keyed namespace are not seen, and are never reaped either: without an `AGENT_LOCK_TTL_SECONDS` they stay in Redis until deleted by hand. Release them before upgrading. The file store is unaffected, since its old records are still read and reaped in the checkout that wrote them.
- Every lock records the `repo` and `branch` it was taken on. A lock written by an earlier version has neither, and is matched by its path on the host that wrote it.
- `release`, `note`, `break` and `resume` find a lock this checkout took on another branch, so switching branches after claiming no longer strands it. That checkout still blocks itself on those files, since they are the same files on disk. `release` and `note` take the lock this session owns when another checkout holds the same scope on the new branch.
- A detached HEAD is keyed by its path on its own host, so two machines with a checkout at the same path do not collide.
- `resume` refuses (exit 1, `HELD`) when somebody claimed an overlapping scope while the work sat interrupted, and the resumed claim covers the branch the checkout is on now rather than the one the orphan was taken on.
- Reaping a lock from another checkout or another machine no longer clears this checkout's freeze flags on files of the same relative name.
- `.ruby-version` is back on 4.0.6. CI still runs the suite on both 4.0.6 and 4.1.0-preview1.

### Fixed

- `erb` is pinned off the yanked 6.1.0, which had made `bundle install` fail on a clean machine and in CI.
- The CLI specs now stay on the test Redis database. Aruba ran them in its own environment, so on the Redis backend they wrote into database 0 of the developer's own Redis, and leftover locks leaked into later examples.

## [3.0.0] - 2026-10-13

### Changed

- **Breaking:** `alock skill install` and `alock skill path` are now `alock skills install` and `alock skills path`. The old `skill` spelling is gone.
- `alock skills install --help` names every skill it installs, and renders at all: an empty example string used to crash dry-cli-help, and the launcher exited 0 with no output.
- Development moves to Ruby 4.1.0-preview1 (`.ruby-version`). CI runs the suite on both 4.0.6 and 4.1.0-preview1, and rubocop on whatever `.ruby-version` names. `required_ruby_version` is unchanged.
- Development and test gems are grouped in the `Gemfile`.
- The spec suite uses a local Redis when one answers, even if `REDIS_URL` is set.

## [2.1.0]

### Added

- Help screens come from `dry-cli-help`: `alock -h` now opens with the gem's title and a description of what it does and how the two backends are chosen, lists commands in registration order, and wraps everything at 85 columns. The hand-written backend banner that used to print above dry-cli's own help is gone.

### Changed

- Finding a Redis now cascades: `REDIS_URL` is tried first when it is set, then `redis://127.0.0.1:6379/0`, and only when neither answers does a virgin tree default to the file store. Previously `REDIS_URL` replaced the local default rather than preceding it, so a shared Redis being down sent the tree straight to the filesystem even with one running locally. `RedisStore.url` now reports the URL that actually answered.

## [0.2.0]

### Added

- An `agent-lock` skill, shipped in the gem under `skills/`, that teaches an agent to claim files: naming itself on every call, running `alock` in the checkout it writes, and claiming its own files inside an orchestrator's lock. `alock skill install [--into DIR] [--force]` copies it into a skills directory, and `alock skill path` prints where the bundled copy is. `--for claude` installs into `~/.claude/skills`; without `--for` or `--into`, `~/.agents/skills` is the default for most other agents.
- `AGENT_LOCK_MUTEX_TIMEOUT`, the seconds a claim waits for the store's mutex.
- `whoami`, which prints the name this session signs locks with, its parent, and where each came from.
- A virgin tree now defaults to the Redis backend when one answers on `REDIS_URL`, and the file store when none does, rather than always defaulting to file. `AGENT_LOCK_BACKEND` still overrides it, and a tree that already has a backend recorded stays on it regardless of what Redis is doing. Two processes racing to decide the default for the same virgin tree are made to agree: the marker recording the choice is claimed with `O_CREAT|O_EXCL`, and every process builds from whichever value actually lands on disk rather than its own guess. See `README.md#backends`.
- Colorized `--help` and error output via `pastel`, disabled automatically when stdout is not a terminal.
- `AGENT_LOCK_TEST_BACKEND`, which runs the whole spec suite against Redis instead of the file store. CI now runs the suite once per backend.

### Changed

- The packaged gem no longer includes `.plans/`.
- `redis` and `pastel` are now runtime dependencies of the gem, rather than gems you install yourself to opt into the Redis backend: deciding the default now means probing for Redis whether or not you asked for it.
- A sub-agent that sets `AGENT_ID` but not `AGENT_PARENT_ID` takes its session's own name as its parent: `CLAUDE_SESSION_ID` if set, else the fingerprint. Claude Code runs sub-agents inside the parent's own process, so without this every sub-agent signed locks as the parent and none could block another.
- Ownership no longer runs upwards. `mine`, `release`, `release-all` and `note` cover your own locks and your sub-agents', never your parent's, so a sub-agent finishing up no longer releases the orchestrator's claim.
- A sub-agent asking for exactly its parent's scope is refused with exit 1 and told to claim something narrower.
- A scope that is empty, or that resolves outside the tree, is refused with exit 2. An empty scope used to mean the whole tree, and `/etc/passwd` used to become a lock on the tree-local file `passwd`. Absolute paths inside the tree, globs included, are made relative.
- `list` counts only live locks as held, lists interrupted ones separately, and tags a live lock past the stale window `STALE`, as do `check` and `mine`. `--json` carries `stale`.
- Hints and error messages name the program that was run, `alock` or `agent-lock`.
- `whoami` without `AGENT_ID` warns that every sub-agent of the session shares that name.

### Fixed

- A sub-agent claiming inside its parent's lock was told `ALREADY YOURS` and nothing was recorded, so two siblings could both claim the same file. The sub-agent now gets a lock of its own, which blocks its siblings.
- Claims on overlapping scopes with different names raced: the conflict scan and the write were separate steps, and `O_EXCL` or `SET NX` only guard an identical scope. Ten parallel claims of `lib/**` and `lib/aN.rb` left up to eleven overlapping locks. Every claim now scans and writes under one store-wide mutex: `flock` on the file store, a leased `SET NX PX` key released by compare-and-delete on Redis.
- Holding one file and asking for a wider scope answered `ALREADY YOURS` and wrote nothing, so the rest of the wider scope stayed open. Only a lock that contains the requested scope counts as already yours now.
- A live holder's lock was reaped once it was older than the stale window, measured from when it was taken, so an agent working for more than two hours lost its lock while still writing. A lock on this machine is now cleared only when its holder has exited; one from another machine expires when untouched past the window, and `note` counts as a touch.
- The `resume` and `break` hints printed before the listing they belong to whenever stdout and stderr went down one pipe, which is how an agent harness reads them. Stdout is flushed before a hint is written.
- A scope starting with a dot, such as `.plans/**` or `.github/**`, produced a lock file whose name also started with one, and the file store's `Dir.glob` skipped it. The lock was written and then enumerated nowhere, so `list`, `mine` and `check` reported it absent and a second session was free to acquire an overlapping scope. Both agents were told they held it.

## [0.1.0]

First release.

- `acquire`, `release`, `check`, `list`, `mine`, `release-all`, `break`, plus `note` and `resume` for work a crash interrupted.
- Session identity: `AGENT_ID`, else `CLAUDE_SESSION_ID`, else a fingerprint of the first ancestor process that is not a shell, so a lock survives the fresh shell an agent harness starts for every command.
- Locks live in `.git/agent-locks`, one store per repository, shared by every worktree and untrackable by git.
- Glob scopes, and a conflict rule that refuses rather than guesses.
- Sub-agents work inside a parent's claim; siblings block each other.
- Stale locks are reaped by liveness, and orphaned rather than deleted when they carry notes.
- Optional Redis backend, chosen explicitly and recorded per tree.
- Optional `--enforce` freeze via `chflags uchg` on macOS.
