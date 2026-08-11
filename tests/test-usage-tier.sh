#!/bin/sh
# Run: sh tests/test-usage-tier.sh   (Git Bash / any POSIX sh)
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/usage-tier.sh"
FIXTURE="$(cd "$(dirname "$0")" && pwd)/fixtures/report.txt"
FAILS=0

assert_eq() { # actual expected name
    if [ "$1" = "$2" ]; then echo "ok  $3"
    else echo "FAIL $3"; echo "  expected: $2"; echo "  actual:   $1"; FAILS=$((FAILS+1)); fi
}

sandbox() {
    D="$(mktemp -d)"
    mkdir -p "$D/usage" "$D/claw"
    export USAGE_AWARE_DIR="$D/usage" CLAWDOMETER_DIR="$D/claw" USAGE_AWARE_NO_SPAWN=1
    unset USAGE_AWARE_REFRESH
}

write_live() { # week_pct age_minutes
    epoch=$(( $(date +%s) + 172800 ))
    printf '{"rate_limits":{"five_hour":{"used_percentage":32,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
        "$epoch" "$1" "$epoch" > "$D/claw/live.json"
    touch_age "$D/claw/live.json" "$2"
}

write_cache() { # week_pct age_minutes
    printf '{"week_pct":%s,"week_resets":"Jul 16, 9:59am","session_pct":32,"session_resets":"Jul 13, 3:29pm"}' \
        "$1" > "$D/usage/cache.json"
    touch_age "$D/usage/cache.json" "$2"
}

touch_age() { # file age_minutes  (backdate mtime)
    ts=$(( $(date +%s) - $2 * 60 ))
    if date -d "@$ts" '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
        touch -t "$(date -d "@$ts" '+%Y%m%d%H%M.%S')" "$1"   # GNU
    else
        touch -t "$(date -r "$ts" '+%Y%m%d%H%M.%S')" "$1"    # BSD
    fi
}

MID=$(printf '\302\267')  # U+00B7 in UTF-8

# tier boundaries via fresh cache
for case in "59 normal" "60 frugal" "85 frugal" "86 minimal"; do
    pct=${case% *}; tier=${case#* }
    sandbox; write_cache "$pct" 1
    out="$(sh "$HOOK")"
    assert_eq "$out" "[usage] week ${pct}% ${MID} session 32% ${MID} week resets Jul 16, 9:59am ${MID} tier: ${tier}" "tier boundary $pct"
done

# stale live + fresh cache -> cache
sandbox; write_live 70 20; write_cache 10 1
assert_eq "$(sh "$HOOK")" "[usage] week 10% ${MID} session 32% ${MID} week resets Jul 16, 9:59am ${MID} tier: normal" "stale live, fresh cache"

# both stale -> stale line, no tier
sandbox; write_cache 45 60
assert_eq "$(sh "$HOOK")" "[usage] week 45% ${MID} session 32% ${MID} week resets Jul 16, 9:59am (stale)" "stale line no tier"

# missing -> silence
sandbox
assert_eq "$(sh "$HOOK")" "" "missing sources silent"

# guard
sandbox; write_cache 45 1
out="$(USAGE_AWARE_REFRESH=1 sh "$HOOK")"
assert_eq "$out" "" "refresh guard silent"

# refresher parses fixture into cache
sandbox
mkdir -p "$D/bin"
printf '#!/bin/sh\ncat "%s"\n' "$FIXTURE" > "$D/bin/claude"
chmod +x "$D/bin/claude"
PATH="$D/bin:$PATH" sh "$HOOK" --refresh
grep -q '"week_pct": *39' "$D/usage/cache.json" && echo "ok  refresher week_pct" || { echo "FAIL refresher week_pct"; FAILS=$((FAILS+1)); }
grep -q '"session_pct": *32' "$D/usage/cache.json" && echo "ok  refresher session_pct" || { echo "FAIL refresher session_pct"; FAILS=$((FAILS+1)); }

[ "$FAILS" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$FAILS FAILED"; exit 1
