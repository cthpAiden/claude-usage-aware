---
name: usage-aware
description: Adapt behavior to the account's Claude rate-limit budget. Use when the user asks "how much usage/limit do I have left", "am I close to my limit", "check my usage", or when a [usage] line in context shows tier frugal/minimal and you are about to start expensive work (subagents, workflows, large reads).
---

# usage-aware

A SessionStart hook injects one line at session start:

    [usage] week 39% · session 32% · week resets Jul 16, 9:59am · tier: normal

`week` is the 7-day all-models window — it drives the tier. `session` is the
5-hour window — display only, never throttle on it (it resets too fast).

## Tiers

| Week % | Tier | Behavior |
|---|---|---|
| < 60 | normal | No change. |
| 60–85 | frugal | No subagents or workflows unless the user asks. Targeted reads (Grep, offset/limit) over whole-file reads. No speculative refactors or drive-by cleanups. Prefer editing over regenerating. |
| > 85 | minimal | Smallest change that works. Confirm with the user before any subagent, workflow, or read over ~500 lines. No exploratory searches beyond what the task strictly needs. |

## Rules

- No `[usage]` line, or a line marked `(stale)` with no tier → behave normally.
  Missing data must never throttle.
- When starting a long or expensive task and the `[usage]` line is over an
  hour old, re-read the freshest of `~/.clawdometer/live.json`
  (`rate_limits.seven_day.used_percentage`) or
  `~/.claude/usage-aware/cache.json` (`week_pct`) with the Read tool and
  recompute the tier. Do NOT run `claude -p /usage` yourself — the hook's
  background refresher handles fetching.
- When the user asks how much usage they have left, report both windows and
  reset times from the freshest source above, plus the current tier.