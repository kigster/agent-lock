# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor, etc.) working in
this repository. See `README.md` for what the gem does and how it works;
this file covers only what an agent needs to know that isn't obvious from
reading the code.

## Checks before calling anything done

```bash
bundle exec rspec                                # file backend, the default
AGENT_LOCK_TEST_BACKEND=redis bundle exec rspec   # same suite, against Redis
bundle exec rubocop
```

Both spec runs and rubocop must be clean. CI (`.github/workflows/main.yml`)
runs the suite once per backend plus rubocop as a third, independent job —
a change that only passes one backend, or that is only checked against one,
is not verified.

A `justfile` exists for the rest (`just test`, `just ci`, `just format`,
`just publish`, `just release`). **`just lint` currently names `standardrb`,
which is not a dependency of this gem** — that recipe does not work; use
`bundle exec rubocop` instead until it's reconciled.

## The dual-backend test suite

`spec/spec_helper.rb` pins every example to one backend via
`AGENT_LOCK_BACKEND`, read from `AGENT_LOCK_TEST_BACKEND` (default `file`).
This exists because the library's default backend picks Redis when one
answers locally: without the pin, running the suite on a machine with Redis
running writes real lock records into that Redis, under whatever tree digest
a throwaway checkout hashes to, with nothing to ever clean them up. It has
happened.

If you add a spec that is inherently about one backend's own on-disk or
on-Redis shape (not just the `Store` contract both satisfy), pin it to that
backend explicitly regardless of `AGENT_LOCK_TEST_BACKEND` — see
`manager_spec.rb`'s "the store the locks live in" block for the pattern.

Redis-backed tests use a fixed test database
(`RedisHelpers::TEST_REDIS_URL`, `spec/support/redis.rb`), never whatever
`REDIS_URL` happens to be set to in the shell — a `flush_test_redis!` runs
after every example. Do not make that depend on an ambient env var again;
an unrelated project's `.envrc` exporting `REDIS_URL` is exactly the failure
mode that guards against, and it has bitten this exact repo's own tooling
(see the git log for "Never let ambient REDIS_URL decide what the suite
flushes").

## Naming: `FileSystemStore` / `RedisStore`, not `FileSystem` / `Redis`

The two backend classes are named with a `Store` suffix
(`Agent::Lock::Store::FileSystemStore`, `Agent::Lock::Store::RedisStore`),
deliberately, so that `RedisStore.new` inside `lib/agent/lock/store/redis_store.rb`
is never confused with `Redis.new` (the `redis` gem's own client class) at a
glance. Any reference to the gem's `Redis` class from inside
`Agent::Lock::Store::RedisStore` still needs a leading `::` to escape the
enclosing module, but keeping the class itself named `RedisStore` avoids
the sharper version of that trap, where an *unqualified* `Redis` inside a
class literally named `Redis` silently resolves to itself.

## Backend selection is a security-relevant path

`Store.for` decides a virgin tree's backend once and records it in a marker
file; every later process in that tree is bound to it regardless of what
Redis is doing. That marker is claimed atomically (`O_CREAT|O_EXCL`) so two
processes racing to open the same virgin tree can't end up on different
backends and silently stop seeing each other's locks — worse than no lock
at all. See `lib/agent/lock/store.rb`'s moduledoc before changing anything
in `.for`, `.claim`, or `.default_backend`.

## Branch stacking

`kig/add-autocomplete` (PR #4) is currently rebased on top of
`kig/fix-concurrent-agent-locking` (PR #3), not on `main`, to keep them from
diverging into a large manual conflict resolution later. Its diff against
`main` will look large — it includes PR #3's commits — until PR #3 merges.
If you rebase either branch again, verify both spec backends and rubocop
afterward per the checks above, and force-push with `--force-with-lease`.

## Known gaps (not yet fixed, tracked via PR review comments on PR #3)

`Manager`'s store-wide mutex covers `acquire`/`resume` but not `note`,
`release`, `break_lock`, `release_all`, or the bare `reap` in `list`/`mine`;
those still do read-modify-write outside it. The Redis mutex lease is not
renewed while its critical section runs, so a slow `reap` (which can shell
out to `ps` per local holder) can outlive it. Treat any change that widens
what runs inside those bare `reap` calls, or that makes a critical section
slower, as touching this.
