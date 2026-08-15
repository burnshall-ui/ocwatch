#!/usr/bin/env bash
# End-to-end check: build a real tree, provoke real inotify events, assert the
# log. The unit tests cover eventStr; this covers everything that only shows up
# against a live kernel — recursive watch setup, the two halves of an atomic
# rename arriving as a pair, watches added for directories created after
# startup, and the tree-structure changes that inotify does not handle for us.
#
# inotify is not recursive and its watches follow the inode, not the path. So
# every scenario below that moves a directory is a place where the watcher can
# quietly start reporting fiction, and a log that invents paths is worse than
# one with gaps: a gap shows up when you count, a wrong path never does.
set -euo pipefail

BIN="${1:-zig-out/bin/ocwatch}"
[ -x "$BIN" ] || { echo "no binary at $BIN — run 'zig build' first" >&2; exit 1; }
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

WORK="$(mktemp -d)"
PID=""
trap 'kill "$PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

fail=0
LOG=""

# Block until the watcher has actually established its watches. Sleeping a
# fixed amount instead is what makes this kind of test flaky on loaded CI.
wait_for_start() {  # $1 = log file, $2 = watch root (for the error message)
  for _ in $(seq 1 50); do
    if [ -s "$1" ] && grep -q START "$1"; then return 0; fi
    sleep 0.1
  done
  echo "  FAIL  watcher never logged START (root=$2)"
  fail=1
}

# Every watcher runs under `timeout` so a hang fails the suite instead of
# wedging CI — and so scenarios that assert on the exit code can just wait.
start_watcher() {  # $1 = watch root, $2 = log file, $3 = timeout seconds
  timeout "${3:-20}" "$BIN" "$1" "$2" >/dev/null 2>&1 &
  PID=$!
  wait_for_start "$2" "$1"
}

stop_watcher() {
  [ -n "$PID" ] || return 0
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""
}

expect() {
  if grep -qE "$1" "$LOG"; then
    echo "  ok    $2"
  else
    echo "  FAIL  $2"
    fail=1
  fi
}

# The counterpart to expect. Several of the failures worth catching here are
# lines that should never have been written, not lines that are missing.
expect_absent() {
  if grep -qE "$1" "$LOG"; then
    echo "  FAIL  $2"
    echo "        offending line: $(grep -E "$1" "$LOG" | head -1 | cut -c1-160)"
    fail=1
  else
    echo "  ok    $2"
  fi
}

# ──────────────────────────────────────────────
echo "events on a live tree:"
LOG="$WORK/basic.log"
mkdir -p "$WORK/basic/watched/nested"
start_watcher "$WORK/basic/watched" "$LOG"

echo "hello" > "$WORK/basic/watched/nested/note.md"           # WRITE
sleep 0.2
mv "$WORK/basic/watched/nested/note.md" \
   "$WORK/basic/watched/nested/final.md"                      # RENAME pair
sleep 0.2
mkdir "$WORK/basic/watched/late"                              # CREATE + new watch
sleep 0.3
echo "x" > "$WORK/basic/watched/late/after.md"                # WRITE in a dir created after startup
sleep 0.2
rm "$WORK/basic/watched/nested/final.md"                      # DELETE
sleep 0.4
stop_watcher

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

# Timestamps must stay parseable — the log is meant to be grepped and sorted —
# and must carry the zone, since the value is UTC on a box that usually is not.
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z  ' "$LOG"; then
  echo "  ok    timestamp format is ISO8601 UTC"
else
  echo "  FAIL  timestamp format is ISO8601 UTC"
  fail=1
fi

# ──────────────────────────────────────────────
echo
echo "a directory moved into the tree:"
# inotify reports this to the parent as MOVED_TO|ISDIR, not CREATE. Nothing
# walks the newcomer, so without explicit handling the whole subtree — and
# every write in it — stays invisible for the life of the process.
LOG="$WORK/movein.log"
mkdir -p "$WORK/movein/watched" "$WORK/movein/outside/payload"
echo "before" > "$WORK/movein/outside/payload/existing.md"
start_watcher "$WORK/movein/watched" "$LOG"

mv "$WORK/movein/outside/payload" "$WORK/movein/watched/payload"
sleep 0.3
echo "after" > "$WORK/movein/watched/payload/arrived.md"
sleep 0.4
stop_watcher

expect 'RENAME-TO.*watched/payload'            "the arriving directory itself is recorded"
expect 'WRITE .*watched/payload/arrived\.md'   "writes inside a moved-in directory are seen"

# ──────────────────────────────────────────────
echo
echo "a watched directory renamed in place:"
# The watch survives the rename because it is bound to the inode, but the path
# cached alongside it does not get updated — so events keep being attributed to
# a path that no longer exists.
LOG="$WORK/rename.log"
mkdir -p "$WORK/rename/watched/before"
start_watcher "$WORK/rename/watched" "$LOG"

mv "$WORK/rename/watched/before" "$WORK/rename/watched/after"
sleep 0.3
echo "data" > "$WORK/rename/watched/after/inside.md"
sleep 0.4
stop_watcher

expect 'WRITE .*watched/after/inside\.md'   "writes after a rename carry the new path"
expect_absent 'watched/before/inside\.md'   "the stale pre-rename path is never reported"

# ──────────────────────────────────────────────
echo
echo "a directory moved out of the tree:"
# Same inode-bound watch, opposite direction: the watcher keeps receiving
# events for a directory that has left its mandate, and renders them under the
# old in-tree path. That is the failure mode that makes the log actively lie.
LOG="$WORK/moveout.log"
mkdir -p "$WORK/moveout/watched/leaving" "$WORK/moveout/elsewhere"
start_watcher "$WORK/moveout/watched" "$LOG"

mv "$WORK/moveout/watched/leaving" "$WORK/moveout/elsewhere/gone"
sleep 0.3
echo "secret" > "$WORK/moveout/elsewhere/gone/outside.md"
sleep 0.4
stop_watcher

expect 'RENAME-FROM.*watched/leaving'   "the departing directory is recorded"
expect_absent 'outside\.md'             "writes outside the tree are not reported at all"
expect_absent 'watched/leaving/'        "no events are attributed to the vacated path"

# ──────────────────────────────────────────────
echo
echo "a path longer than the log line buffer:"
# Paths are accepted up to MAX_PATH, but the line is formatted into a much
# smaller buffer. Past that width the event is dropped with no diagnostic —
# the one case where the tool loses data and says nothing at all.
LOG="$WORK/deep.log"
deep="$WORK/deep/root"
mkdir -p "$deep"
comp="$(printf 'd%.0s' $(seq 1 100))"
for _ in $(seq 1 14); do
  deep="$deep/$comp"
done
mkdir -p "$deep"

# Guard the fixture itself: if the path drifts out of this window the scenario
# silently stops testing what its name claims.
deep_len=${#deep}
if [ "$deep_len" -lt 1300 ] || [ "$deep_len" -gt 3900 ]; then
  echo "  FAIL  fixture: deep path is $deep_len chars, outside the intended window"
  fail=1
fi

start_watcher "$WORK/deep/root" "$LOG"
echo "data" > "$deep/deep.md"
echo "data" > "$WORK/deep/root/shallow.md"
sleep 0.5
stop_watcher

expect 'WRITE .*/shallow\.md'   "control: a short path in the same run is logged ($deep_len-char sibling)"
expect 'WRITE .*/deep\.md'      "a path longer than the line buffer is not silently dropped"

# ──────────────────────────────────────────────
echo
echo "the hidden-directory filter:"
# The filter used to be applied only while scanning, which made it depend on
# when a directory appeared rather than on what it is: a .git already present
# at startup was skipped, while the identical directory created a second later
# was watched and logged.
LOG="$WORK/hidden.log"
mkdir -p "$WORK/hidden/watched/.git_pre" "$WORK/hidden/watched/.openclaw_keep"
start_watcher "$WORK/hidden/watched" "$LOG"

echo "x" > "$WORK/hidden/watched/.git_pre/present.md"
mkdir "$WORK/hidden/watched/.git_post"
sleep 0.3
echo "x" > "$WORK/hidden/watched/.git_post/late.md"
echo "x" > "$WORK/hidden/watched/.openclaw_keep/kept.md"
sleep 0.5
stop_watcher

expect_absent 'git_pre/present\.md'   "a filtered directory present at startup stays unwatched"
expect_absent 'git_post'              "the same directory created at runtime is filtered identically"
expect 'openclaw_keep/kept\.md'       "openclaw's own dot-directories are still watched"

# ──────────────────────────────────────────────
echo
echo "a watcher that cannot see its root:"
# With zero watches the process blocks forever on an empty inotify fd. systemd
# reports it as active(running) and Restart=on-failure never fires, so it is
# broken in exactly the way that is hardest to notice. Better honestly dead.
rc=0
timeout 5 "$BIN" "$WORK/does-not-exist" "$WORK/missing.log" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 124 ]; then
  echo "  FAIL  missing root: watcher hung instead of exiting"
  fail=1
elif [ "$rc" -eq 0 ]; then
  echo "  FAIL  missing root: watcher exited 0, reporting success"
  fail=1
else
  echo "  ok    missing root exits non-zero ($rc)"
fi

LOG="$WORK/vanish.log"
mkdir -p "$WORK/vanish/watched"
start_watcher "$WORK/vanish/watched" "$LOG" 8
rmdir "$WORK/vanish/watched"
rc=0
wait "$PID" 2>/dev/null || rc=$?
PID=""
if [ "$rc" -eq 124 ]; then
  echo "  FAIL  deleted root: watcher kept running blind"
  fail=1
elif [ "$rc" -eq 0 ]; then
  echo "  FAIL  deleted root: watcher exited 0, reporting success"
  fail=1
else
  echo "  ok    deleted root exits non-zero ($rc)"
fi
expect 'DELETE-SELF .*watched' "the root's disappearance is logged before exiting"

# ──────────────────────────────────────────────
if [ "$fail" -ne 0 ]; then
  echo
  echo "--- full logs ---"
  for f in "$WORK"/*.log; do
    [ -e "$f" ] || continue
    echo "### $(basename "$f")"
    cut -c1-200 "$f"    # deep-path lines would otherwise flood the terminal
    echo
  done
  exit 1
fi

echo
echo "integration: all checks passed"
