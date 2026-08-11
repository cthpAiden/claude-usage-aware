# claude-usage-aware

A standalone Claude Code skill and `SessionStart` hook that makes Claude aware
of how much of your Claude rate-limit budget you've used, and adjusts its own
behavior to match. At the start of every session, a hook injects one line
into context with your weekly and session usage percentages and a behavior
tier; `SKILL.md` (installed alongside it) tells Claude how to read that tier
and scale back — fewer unrequested subagents, more targeted reads, smaller
diffs — as the budget tightens, without you having to ask. When no usage data
is available the hook stays silent and Claude behaves exactly as it would
without this skill: missing data never throttles anything.

## The `[usage]` line

```
[usage] week 39% · session 32% · week resets Jul 16, 9:59am · tier: normal
```

- **`week`** — percent used of the rolling 7-day, all-models window. This is
  the number the tier is computed from.
- **`session`** — percent used of the rolling 5-hour window. Display only —
  it resets too fast to safely throttle on, so it never affects the tier.
  Omitted if the data source didn't report it.
- **`week resets`** — when the weekly window resets. When the line comes from
  the refresher's cache this is the CLI's own text, unchanged; when it comes
  from Clawdometer's `live.json` (a raw Unix timestamp), the hook converts
  and formats it itself, in your local timezone.
- **`tier`** — `normal`, `frugal`, or `minimal`, computed from `week` (see
  [Tiers](#tiers) below).

If the freshest available data is old but not too old, the hook shows it
anyway, marked `(stale)`, with the `tier` segment dropped entirely:

```
[usage] week 45% · session 32% · week resets Jul 16, 9:59am (stale)
```

If nothing usable is available at all, the hook prints nothing — see
[Troubleshooting](#troubleshooting).

## Tiers

`SKILL.md` instructs Claude to read the weekly percentage and self-adjust:

| Week % | Tier | Behavior |
|---|---|---|
| < 60 | normal | No change. |
| 60–85 | frugal | No subagents or workflows unless the user asks. Targeted reads (Grep, offset/limit) over whole-file reads. No speculative refactors or drive-by cleanups. Prefer editing over regenerating. |
| > 85 | minimal | Smallest change that works. Confirm with the user before any subagent, workflow, or read over ~500 lines. No exploratory searches beyond what the task strictly needs. |

No `[usage]` line, or a `(stale)` line with no tier, means "behave normally"
— the skill is designed to fail open, never closed.

## How it works: data sources

Every session start, the hook picks the freshest of three sources, in
priority order:

1. **Clawdometer's `~/.clawdometer/live.json`**, if it exists and was
   written in the last 15 minutes. If you run the
   [Clawdometer](https://github.com/cthpAiden/Clawdometer) HUD, this is free
   and effectively instant — usage-aware only ever reads this file; it never
   talks to Clawdometer or writes to its directory.
2. **This skill's own `~/.claude/usage-aware/cache.json`**, if it exists and
   was written in the last 10 minutes. Written by the refresher below.
3. **A detached, backgrounded `claude -p --no-session-persistence /usage`**,
   kicked off when neither of the above is fresh. This never blocks session
   start — the hook starts it and returns immediately, so its output can't
   appear until a *later* session reads the cache it fills in.

The refresher parses the `Current week (all models): NN% used · resets ...`
and `Current session: NN% used · resets ...` lines out of `/usage`'s output
and writes them to `cache.json` atomically (write-to-temp-then-rename, so a
concurrent session's hook never reads a half-written file). It's killed after
60 seconds if `claude` hangs, and a lockfile
(`~/.claude/usage-aware/refresh.lock`) stops multiple sessions from piling up
refreshers at once — a lock younger than 5 minutes suppresses a new spawn.

If the freshest source is older than its window above but under 24 hours
old, the hook still prints it, tagged `(stale)`. Past 24 hours, or if
nothing exists yet, it prints nothing — in both cases it also kicks off a
background refresh so the *next* session has something current.

## Install

Windows only, from the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

This copies `SKILL.md` to `~/.claude/skills/usage-aware/SKILL.md`, copies
`hooks/usage-tier.ps1` to `~/.claude/hooks/usage-tier.ps1`, and registers a
`SessionStart` hook command in `~/.claude/settings.json` that runs it. The
merge is additive and idempotent:

- Existing `settings.json` content — other keys, other hooks — is preserved.
  Running the installer again doesn't add a second `usage-tier.ps1` entry.
- If `settings.json` already existed, it's copied to
  `settings.json.bak-<timestamp>` in the same folder *before* being touched.
- Restart any open Claude Code sessions afterward; the hook only fires at
  session start.

Set `USAGE_AWARE_INSTALL_ROOT` before running the installer to target a root
other than `~/.claude` (mainly useful for testing).

**macOS / Linux:** `hooks/usage-tier.sh` is a POSIX port with the same
sources and the same output format, covered by its own test suite
(`tests/test-usage-tier.sh`) — but there's no installer for it yet. Wire it
up by hand: copy `SKILL.md` and `hooks/usage-tier.sh` under `~/.claude/`,
then add a `SessionStart` entry to `~/.claude/settings.json` whose command
runs `sh ~/.claude/hooks/usage-tier.sh`.

## Uninstall

1. Delete the skill: `~/.claude/skills/usage-aware`
2. Delete the hook script: `~/.claude/hooks/usage-tier.ps1` (and
   `usage-tier.sh`, if you wired up the POSIX port by hand)
3. Remove the `SessionStart` entry pointing at `usage-tier.ps1` (or
   `usage-tier.sh`) from `~/.claude/settings.json` — it's the array element
   under `hooks.SessionStart` whose `command` mentions the script. If you
   still have the installer's `settings.json.bak-<timestamp>` from before
   you made any other changes, restoring it is an equally valid shortcut.
4. Delete the cache directory: `~/.claude/usage-aware/` (`cache.json`,
   `refresh.lock`, `refresh-out.txt`)

None of this touches `~/.clawdometer/` — usage-aware never writes there.

## Troubleshooting

**No `[usage]` line at session start.** Most commonly this just means both
data sources were missing or stale when that session started — the hook
fails silent rather than show numbers that might be wrong as if they were
current. Concretely:

- If Clawdometer's HUD is already running, its `live.json` should be warm
  and the line should appear from the very first session. If it doesn't,
  check that Clawdometer is actually running and pointed at
  `~/.clawdometer`.
- Otherwise, the **first** session after install (or after a long gap
  without one) has nothing to read, prints nothing, and silently starts a
  background refresh. That refresh takes anywhere from a few seconds to
  under a minute. The **second** session then reads the now-fresh
  `cache.json` and shows the line.

If it's still missing after that:

- Check `~/.claude/settings.json` has a `SessionStart` entry whose command
  mentions `usage-tier.ps1`.
- Check `claude` is on `PATH` — the refresher shells out to it, and if it
  can't find `claude` it fails open and silently, so `cache.json` never gets
  written.
- Force a refresh and inspect it directly:
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\hooks\usage-tier.ps1" -Refresh
  Get-Content "$HOME\.claude\usage-aware\cache.json"
  powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\hooks\usage-tier.ps1"
  ```
- If `claude -p --no-session-persistence /usage`'s wording has changed since
  this was written (captured against CLI v2.1.207), the refresher's parser
  won't match it and will silently keep the old cache — compare its output
  against `Current week (all models): NN% used · resets <text> (`.

## Advanced: environment variables

Mainly for testing; not needed for normal use.

| Variable | Effect |
|---|---|
| `USAGE_AWARE_INSTALL_ROOT` | Installer target root, instead of `~/.claude`. |
| `USAGE_AWARE_DIR` | Hook's cache/lock directory, instead of `~/.claude/usage-aware`. |
| `CLAWDOMETER_DIR` | Hook's Clawdometer directory, instead of `~/.clawdometer`. |
| `USAGE_AWARE_NO_SPAWN` | Set to `1` to suppress the background refresher spawn. |
| `USAGE_AWARE_REFRESH` | Internal recursion guard set by the refresher's own `claude` child; don't set this by hand. |

## Testing

```bash
powershell -NoProfile -File tests/test-usage-tier.ps1   # hook logic, sandboxed (fake claude on PATH)
powershell -NoProfile -File tests/test-install.ps1       # installer, sandboxed (fake ~/.claude root)
sh tests/test-usage-tier.sh                              # POSIX port of the hook logic
```

All three are self-contained: they run against temp directories and a fake
`claude` shim, never your real account or `~/.claude`.

## Design docs

For the full rationale and step-by-step implementation plan:
[design spec](docs/superpowers/specs/2026-08-12-usage-aware-skill-design.md),
[implementation plan](docs/superpowers/plans/2026-08-12-usage-aware-skill.md).
