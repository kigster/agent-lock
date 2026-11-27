---
name: agent-lock
description: Use when several agents or sub-agents write in one checkout or worktree, before creating or editing files there, when launching sub-agents that will write files, or when `alock` or `agent-lock` answers REFUSED, HELD, STALE or INTERRUPTED WORK.
---

# Claiming files with alock

## Overview

`alock` (the `agent-lock` gem) keeps agents that share a checkout from writing over each other. A lock is advisory: it protects a file only if every writer claims first, under its own name, in the tree it writes in.

## Four ways a claim silently protects nothing

1. **An unnamed sub-agent signs as its parent.** Sub-agents run inside the parent's process, and every Bash call is a fresh shell, so an `export` from an earlier call is gone. Put the name on the same command line, every time: `AGENT_ID=<your-name> alock ...`. The `(holder: ...)` in the reply must be your name.
1. **Two siblings with one name are one holder**, and never block each other. Use the name your orchestrator gave you. Given none, pick the task plus four random characters once, such as `shipping-rates-7f3a`, and type that literal on every call; `$RANDOM` in the prefix changes each time.
1. **A lock in another checkout guards nothing here.** Run `alock` inside the checkout you write in: `cd <checkout> && AGENT_ID=<your-name> alock ...`, or pass `--dir <checkout>`.
1. **An orchestrator's lock does not keep siblings apart.** It keeps other sessions out. Each sub-agent still claims its own files inside it.

## Which store the locks live in

Left alone, `alock` uses Redis when one answers and the file store inside `.git` otherwise, and the first call in a checkout records that choice. The caller can choose instead, and should whenever somebody else chose first:

- **You were given a strategy or a Redis URL** (by your orchestrator, a dispatcher, or your instructions): pass it on every `alock` call that reads or writes locks (`acquire`, `release`, `release-all`, `check`, `list`, `mine`, `note`, `resume`, `break`), not only `acquire`. `whoami` and `version` take neither flag. `-s redis` or `-s filesystem` names the store; `-u <url>` names the one Redis to use and implies `-s redis`.
- **`AGENT_LOCK_REDIS_URL` is already set in your environment:** it means the same as `-u` on every call, so pass no flag and do not unset or change it.
- **You launch sub-agents** and you passed either flag yourself: give each sub-agent the same flags with its name. A different Redis URL is a different store, where nobody sees your locks.
- **You were given neither:** pass neither.

```bash
cd ~/src/shop && AGENT_ID=shipping-rates-7f3a alock acquire "src/shipping/**" "rate tables" -u redis://locks.internal:6379
cd ~/src/shop && AGENT_ID=shipping-rates-7f3a alock release "src/shipping/**" -u redis://locks.internal:6379
```

Exit 2 naming the store means the flags disagree with the checkout or the Redis did not answer. Do not drop the flag to get past it: that puts your lock where nobody else is looking. Report it.

## Recipe

The orchestrator runs `alock` bare, which makes it the parent, and gives each sub-agent a distinct name and the checkout:

```bash
cd ~/src/shop && alock acquire "src/**" "fanning out the pricing work"
```

A sub-agent, under the name it was given. Given none, it uses its own task plus four random characters, chosen once and typed the same on every call; never the example below:

```bash
cd ~/src/shop && AGENT_ID=shipping-rates-7f3a alock whoami                          # id shipping-rates-7f3a, parent inferred
cd ~/src/shop && AGENT_ID=shipping-rates-7f3a alock acquire "src/shipping/**" "rate tables"
cd ~/src/shop && AGENT_ID=shipping-rates-7f3a alock note "src/shipping/**" "rates done, specs red"
cd ~/src/shop && AGENT_ID=shipping-rates-7f3a alock release-all                     # yours and your sub-agents', never your parent's
```

Write only inside what you claimed, and claim the narrowest scope that covers it. A directory means everything under it; `**` is rarely right. Quote globs.

## Reading the answer

| Reply                                    | Exit | What to do                                                                          |
| :--------------------------------------- | :--- | :---------------------------------------------------------------------------------- |
| `ACQUIRED`, `ALREADY YOURS`              | 0    | Write inside the scope                                                              |
| `REFUSED` then `HELD ... by X`           | 1    | Do not write. Work elsewhere, or tell the human who holds it                        |
| `REFUSED: ... your parent's whole claim` | 1    | Claim something narrower inside it                                                  |
| `HELD ... STALE`                         | 1    | The holder is alive but quiet. Ask, or announce, then `alock break`                   |
| `INTERRUPTED WORK`                       | 1    | `alock resume` takes it over with its notes; `alock break` discards it                  |
| `ERROR: alock: ...`                      | 2    | The command could not run: empty scope, a path outside the tree, a store mismatch, a Redis that did not answer |

## Common mistakes

| Mistake                                                             | Result                                                       |
| :------------------------------------------------------------------ | :----------------------------------------------------------- |
| `export AGENT_ID=x` in one call, `alock acquire` in the next          | The lock is signed by the orchestrator and blocks no sibling |
| Two sub-agents inventing the same obvious name                      | They count as one holder, and both get `ALREADY YOURS`       |
| Skipping your own claim because the orchestrator "already holds it" | Two siblings edit one file and the last writer wins          |
| Running `alock` from wherever the shell started                       | The lock lands in another repository                         |
| Writing after a refusal                                             | The collision the lock existed to prevent                    |

Needs `agent-lock` newer than 0.1.0 (`alock version`). Run `alock <command> --help` for flags.
