#!/bin/sh
# usage-tier.sh — SessionStart hook for the usage-aware skill (POSIX port of
# usage-tier.ps1; same sources, same output format, fails open everywhere).

[ "$USAGE_AWARE_REFRESH" = "1" ] && exit 0

USAGE_DIR="${USAGE_AWARE_DIR:-$HOME/.claude/usage-aware}"
CLAW_DIR="${CLAWDOMETER_DIR:-$HOME/.clawdometer}"
LIVE="$CLAW_DIR/live.json"
CACHE="$USAGE_DIR/cache.json"
LOCK="$USAGE_DIR/refresh.lock"
MID=$(printf '\302\267')

fresh() { # file max_age_minutes -> 0 if exists and newer
    [ -f "$1" ] && [ -n "$(find "$1" -mmin "-$2" 2>/dev/null)" ]
}

json_num() { # file key -> first "key":<int> match
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n1
}

json_str() { # file key -> first "key":"..." match
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1
}

fmt_epoch() { # epoch -> "Jul 16, 9:59AM" local time (GNU then BSD date)
    date -d "@$1" '+%b %-d, %-I:%M%p' 2>/dev/null || date -r "$1" '+%b %-d, %-I:%M%p' 2>/dev/null
}

# read_live/read_cache set: WEEK_PCT WEEK_RESETS SESSION_PCT SESSION_RESETS
read_live() {
    seven=$(sed -n 's/.*"seven_day"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$LIVE" 2>/dev/null)
    [ -n "$seven" ] || return 1
    WEEK_PCT=$(printf '%s' "$seven" | sed -n 's/.*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [ -n "$WEEK_PCT" ] || return 1
    epoch=$(printf '%s' "$seven" | sed -n 's/.*"resets_at"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    WEEK_RESETS=$(fmt_epoch "$epoch")
    five=$(sed -n 's/.*"five_hour"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$LIVE" 2>/dev/null)
    SESSION_PCT=$(printf '%s' "$five" | sed -n 's/.*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$SESSION_PCT" ]; then
        sepoch=$(printf '%s' "$five" | sed -n 's/.*"resets_at"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        SESSION_RESETS=$(fmt_epoch "$sepoch")
    fi
    return 0
}

read_cache() {
    WEEK_PCT=$(json_num "$CACHE" week_pct)
    [ -n "$WEEK_PCT" ] || return 1
    WEEK_RESETS=$(json_str "$CACHE" week_resets)
    SESSION_PCT=$(json_num "$CACHE" session_pct)
    SESSION_RESETS=$(json_str "$CACHE" session_resets)
    return 0
}

tier() {
    if [ "$1" -lt 60 ]; then echo normal
    elif [ "$1" -le 85 ]; then echo frugal
    else echo minimal; fi
}

print_line() { # $1 = "fresh" | "stale"
    line="[usage] week ${WEEK_PCT}%"
    [ -n "$SESSION_PCT" ] && line="$line ${MID} session ${SESSION_PCT}%"
    line="$line ${MID} week resets ${WEEK_RESETS}"
    if [ "$1" = "stale" ]; then echo "$line (stale)"
    else echo "$line ${MID} tier: $(tier "$WEEK_PCT")"; fi
}

do_refresh() {
    mkdir -p "$USAGE_DIR"
    echo $$ > "$LOCK"
    out="$USAGE_DIR/refresh-out.txt"
    # Guard env inherits into claude's own SessionStart hook run.
    USAGE_AWARE_REFRESH=1 claude -p --no-session-persistence /usage > "$out" 2>/dev/null &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i+1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; return; fi
    week_line=$(grep 'Current week (all models):' "$out" 2>/dev/null | head -n1)
    [ -n "$week_line" ] || return
    wp=$(printf '%s' "$week_line" | sed -n 's/.*: \([0-9][0-9]*\)% used.*/\1/p')
    wr=$(printf '%s' "$week_line" | sed -n 's/.*resets \(.*\) (.*/\1/p')
    [ -n "$wp" ] || return
    sess_line=$(grep 'Current session:' "$out" 2>/dev/null | head -n1)
    sp=$(printf '%s' "$sess_line" | sed -n 's/.*: \([0-9][0-9]*\)% used.*/\1/p')
    sr=$(printf '%s' "$sess_line" | sed -n 's/.*resets \(.*\) (.*/\1/p')
    {
        printf '{"fetched_at":"%s","week_pct":%s,"week_resets":"%s"' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$wp" "$wr"
        [ -n "$sp" ] && printf ',"session_pct":%s,"session_resets":"%s"' "$sp" "$sr"
        printf '}\n'
    } > "$CACHE.tmp"
    mv -f "$CACHE.tmp" "$CACHE"
}

spawn_refresher() {
    [ "$USAGE_AWARE_NO_SPAWN" = "1" ] && return
    fresh "$LOCK" 5 && return
    mkdir -p "$USAGE_DIR"
    echo $$ > "$LOCK"
    nohup sh "$0" --refresh >/dev/null 2>&1 &
}

if [ "$1" = "--refresh" ]; then do_refresh; exit 0; fi

if fresh "$LIVE" 15 && read_live; then print_line fresh; exit 0; fi
if fresh "$CACHE" 10 && read_cache; then print_line fresh; exit 0; fi

spawn_refresher
if fresh "$LIVE" 1440 && read_live; then print_line stale
elif fresh "$CACHE" 1440 && read_cache; then print_line stale
fi
exit 0
