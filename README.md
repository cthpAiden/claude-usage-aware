# claude-usage-aware

A standalone Claude Code skill + SessionStart hook that makes Claude aware of
the account's rate-limit budget and adapts its behavior to it.

At session start, a hook injects one line into context:

```
[usage] week 39% · session 32% · week resets Jul 16, 9:59am · tier: normal
```

The weekly percentage drives three tiers — `normal` (<60%), `frugal` (60–85%:
no unrequested subagents/workflows, targeted reads), `minimal` (>85%: smallest
change that works, confirm before anything expensive). Missing or stale data
never throttles: the hook fails open.

Data sources, freshest wins:

1. [Clawdometer](https://github.com/cthpAiden/Clawdometer)'s `~/.clawdometer/live.json` (free when the HUD is running)
2. This skill's own `~/.claude/usage-aware/cache.json`
3. A detached background run of `claude -p --no-session-persistence /usage`
   that refills the cache (never blocks session start)

## Status

Design + implementation plan done; implementation not started.

- Spec: [docs/superpowers/specs/2026-08-12-usage-aware-skill-design.md](docs/superpowers/specs/2026-08-12-usage-aware-skill-design.md)
- Plan: [docs/superpowers/plans/2026-08-12-usage-aware-skill.md](docs/superpowers/plans/2026-08-12-usage-aware-skill.md)

To implement: open this repo in Claude Code and execute the plan task-by-task
(it is written for the superpowers `subagent-driven-development` /
`executing-plans` skills). Task 7's README replaces this stub.
