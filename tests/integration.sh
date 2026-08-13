#!/usr/bin/env bash
# End-to-end check: build a real tree, provoke real inotify events, assert the
# log. The unit tests cover eventStr; this covers everything that only shows up
# against a live kernel — recursive watch setup, the two halves of an atomic
# rename arriving as a pair, and watches added for directories created after
# startup.
set -euo pipefail

BIN="${1:-zig-out/bin/ocwatch}"
[ -x "$BIN" ] || { echo "no binary at $BIN — run 'zig build' first" >&2; exit 1; }
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

WORK="$(mktemp -d)"
LOG="$WORK/ocwatch.log"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/watched/nested"

"$BIN" "$WORK/watched" "$LOG" >/dev/null 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Wait for the watch to be established rather than sleeping a fixed amount.
for _ in $(seq 1 50); do
  [ -s "$LOG" ] && grep -q START "$LOG" && break
  sleep 0.1
done
grep -q START "$LOG" || { echo "FAIL: watcher never logged START"; cat "$LOG"; exit 1; }

echo "hello" > "$WORK/watched/nested/note.md"           # WRITE
sleep 0.2
mv "$WORK/watched/nested/note.md" "$WORK/watched/nested/final.md"   # RENAME pair
sleep 0.2
mkdir "$WORK/watched/late"                               # CREATE + new watch
sleep 0.3
echo "x" > "$WORK/watched/late/after.md"                 # WRITE in a dir created after startup
sleep 0.2
rm "$WORK/watched/nested/final.md"                       # DELETE
sleep 0.4

kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

fail=0
expect() {
  if grep -qE "$1" "$LOG"; then
    echo "  ok    $2"
  else
    echo "  FAIL  $2"
    fail=1
  fi
}

echo "events:"
expect 'WRITE .*nested/note\.md'          "write is logged with its path"
expect 'RENAME-FROM .*nested/note\.md'    "rename source half"
expect 'RENAME-TO .*nested/final\.md'     "rename target half"
expect 'WRITE .*late/after\.md'           "directory created after startup is watched too"
expect 'DELETE .*nested/final\.md'        "delete is logged"

# The atomic-rename pair is the whole point of the tool: both halves must be
# present, since only seeing one would misreport a move as a create or delete.
from_n=$(grep -c 'RENAME-FROM' "$LOG" || true)
to_n=$(grep -c 'RENAME-TO' "$LOG" || true)
if [ "$from_n" -eq "$to_n" ] && [ "$from_n" -ge 1 ]; then
  echo "  ok    rename halves are balanced ($from_n/$to_n)"
else
  echo "  FAIL  rename halves unbalanced: $from_n RENAME-FROM vs $to_n RENAME-TO"
  fail=1
fi

# Timestamps must stay parseable — the log is meant to be grepped and sorted.
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}  ' "$LOG"; then
  echo "  ok    timestamp format"
else
  echo "  FAIL  timestamp format"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "--- full log ---"
  cat "$LOG"
  exit 1
fi

echo
echo "integration: all checks passed"
