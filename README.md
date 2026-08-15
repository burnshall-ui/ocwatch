<h1 align="center">o c w a t c h</h1>

<p align="center">
  <strong>Filesystem write monitor for <a href="https://openclaw.dev">OpenClaw</a> agents</strong><br/>
  <em>Catches atomic renames the moment they land — no polling, no libc, no daemon.</em>
</p>

<p align="center">
  <a href="https://github.com/burnshall-ui/ocwatch/actions/workflows/ci.yml"><img src="https://github.com/burnshall-ui/ocwatch/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/Zig-0.16-F7A41D?logo=zig&logoColor=white" alt="Zig 0.16" />
  <img src="https://img.shields.io/badge/Linux-inotify-FCC624?logo=linux&logoColor=black" alt="Linux inotify" />
  <img src="https://img.shields.io/badge/libc-none-1f6feb" alt="No libc" />
  <img src="https://img.shields.io/badge/polling-none-1f6feb" alt="No polling" />
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License" />
</p>

---

Filesystem write monitor for [OpenClaw](https://openclaw.dev) agents. Uses Linux `inotify` to watch `~/.openclaw/` recursively and logs every write, atomic rename, and delete with millisecond timestamps.

```
2026-04-17T01:42:22.263  START         watching /root/.openclaw (62 dirs) → ocwatch.log
2026-04-17T01:48:03.891  RENAME-TO     /root/.openclaw/openclaw.json  [7027B]
2026-04-17T01:48:03.892  RENAME-FROM   /root/.openclaw/openclaw.json.tmp
2026-04-17T01:51:17.440  WRITE         /root/.openclaw/workspace/memory/2026-04-17.md  [1842B]
2026-04-17T01:55:00.012  DELETE        /root/.openclaw/workspace/.tmp_session_abc123
```

## Why

OpenClaw agents perform config writes as atomic renames (temp → final). Catch exactly that — plus session files, memory writes, and dream cycles — without polling.

## Requirements

- Linux (uses `inotify`, `getdents64`, `statx`)
- [Zig](https://ziglang.org) 0.16+ to build
- No libc dependency

## Build

```sh
zig build -Doptimize=ReleaseFast
```

Binary lands at `zig-out/bin/ocwatch`.

## Install

```sh
cp zig-out/bin/ocwatch ~/.local/bin/
```

## Tests

```sh
zig build test --summary all   # unit tests
./tests/integration.sh         # end-to-end against a live kernel
```

The unit tests cover event-mask decoding, including a guard that `WATCH_MASK`
subscribes to exactly the events the logger can name — adding a bit to one
without the other would log real events as `UNKNOWN`.

The integration script builds a directory tree, provokes real inotify events and
asserts the log: both halves of an atomic rename arrive as a balanced pair,
directories created after startup get watched too, and the timestamp format
stays greppable.

## Usage

```
ocwatch [watch-dir] [log-file]
```

| Argument    | Default                              |
|-------------|--------------------------------------|
| `watch-dir` | `/root/.openclaw`                    |
| `log-file`  | `/root/.openclaw/logs/ocwatch.log`   |

Output goes to **both stdout and the log file** simultaneously.

## Run as a service

```sh
# ~/.config/systemd/user/ocwatch.service
[Unit]
Description=OpenClaw Agent Write Monitor
After=openclaw-gateway.service

[Service]
ExecStart=%h/.local/bin/ocwatch %h/.openclaw %h/.openclaw/logs/ocwatch.log
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

```sh
systemctl --user enable --now ocwatch
```

`%h` expands to the home directory of the user the unit runs as, so the same
file works whether that is root or anyone else. `Restart=on-failure` is
load-bearing: ocwatch exits non-zero rather than keep running in any state where
it would observe nothing or cover the tree only partially, and relies on the
supervisor to bring it back.

Note the argument defaults compiled into the binary are still `/root`-based, so
pass both paths explicitly as above rather than relying on them.

### Rotation

ocwatch does not rotate its own log — that is logrotate's job — but it does
constrain how: it holds one `O_APPEND` descriptor for the life of the process
and cannot be told to reopen it, so the file has to be rotated in place.

```
# /etc/logrotate.d/ocwatch
/root/.openclaw/logs/ocwatch.log {
    weekly
    maxsize 20M
    rotate 8
    compress
    notifempty
    missingok
    copytruncate
}
```

`copytruncate` is the part that matters. Rotating by rename would leave ocwatch
writing into an unlinked inode: the new log stays empty and the trail stops
without a word. `O_APPEND` is what makes the truncate safe — writes re-seek to
the end, so the file resumes at offset 0 instead of returning as a sparse hole
the size of the old log. The cost is a small window: anything written between
the copy and the truncate is lost.

For scale, a monitored `~/.openclaw` produced about 77 KB/day over 120 days,
compressing to roughly a tenth. Eight weekly generations is a couple of months
of history in a few megabytes.

## Event types

| Event             | Meaning                                             |
|-------------------|-----------------------------------------------------|
| `WRITE`           | File closed after write (`IN_CLOSE_WRITE`)          |
| `RENAME-TO`       | File renamed here — openclaw's atomic write pattern |
| `RENAME-FROM`     | Source side of a rename                             |
| `DELETE`          | File removed                                        |
| `CREATE-DIR`      | Directory created                                   |
| `DELETE-DIR`      | Directory removed                                   |
| `RENAME-TO-DIR`   | Directory moved into the tree                       |
| `RENAME-FROM-DIR` | Directory moved out of, or within, the tree         |
| `MOVE-SELF`       | A watched directory was itself moved                |
| `DELETE-SELF`     | Watched directory removed                           |

Files are reported on `WRITE`, not on creation, so a new file produces one line
rather than two. Directories have no `CLOSE_WRITE`, so they are reported when
they appear.

### Keeping up with a moving tree

inotify is not recursive, and its watches follow the inode rather than the
path. A directory that is moved therefore keeps its watch but not its meaning:
left alone, the watcher would report writes under a path that no longer exists,
and would go on reporting a directory that has been moved clean out of the
tree. Neither shows up as a gap in the log — it reports fiction instead.

So anything that invalidates the path map — a directory moved in, out or
renamed, or a kernel queue overflow that may have hidden a directory's creation
— triggers a full re-scan from the root, logged as `REBUILD`. Re-scans are
coalesced to one per batch of events, since a single rename raises three.

Directories created outright are cheaper: they are empty by definition, so they
just get a watch, no re-scan.

If a re-scan finds nothing to watch — the root was deleted or moved away —
ocwatch logs the reason and exits non-zero rather than block forever on an
empty inotify instance, so `Restart=` can act on it.

### What is not watched

Hidden directories are skipped unless they are openclaw's own (`.openclaw*`,
`.dreams`, `.clawhub`, `.openclaw-wiki`) — a `.git` in the tree would bury the
trail under object churn. The rule is about what a directory is, not when it
turned up: a filtered directory created while ocwatch is running is skipped
exactly like one that was already there. The watch root itself is never
filtered, since it is named explicitly and is usually `~/.openclaw`.

## Log format

```
<ISO8601-ms-UTC>  <EVENT>          <full-path>  [<size>B]
```

Timestamps are UTC and say so with a trailing `Z`, so they line up with
`journalctl --utc` rather than looking like local time.

Size is shown for file `WRITE` and `RENAME-TO` events via `statx(2)`.

Diagnostics share the same shape, in the `<EVENT>` column: `REBUILD`,
`Q-OVERFLOW` (kernel queue overflowed, events were lost), `NO-DESCEND` (watched
but not readable, so its subdirectories are not covered), `WATCH-LIMIT`,
`DEPTH-LIMIT`, `LINE-OVERFLOW`, and the `*-ERR` tags. They exist so that every
way this tool can lose sight of something leaves a line behind.

The log file is created `0600`, and any log directory it creates `0700` — a
record of every file an agent touched is a map of the system for whoever can
read it. The log is opened with `O_NOFOLLOW`, so a symlink in that position
fails at startup instead of being appended through.

### When it exits

ocwatch exits non-zero rather than continue in any state where it would observe
less than it claims to:

| Condition | Why it is fatal |
|-----------|-----------------|
| No watchable root | Blocks forever on an empty inotify instance, looking healthy |
| Last watch gone | Same state, reached at runtime |
| Log writes failing | Watching perfectly and recording nothing |
| More directories than `MAX_WATCH_DIRS` | Coverage would be partial, and partial lines look complete |
| Tree deeper than `MAX_DEPTH` | Same, and unbounded recursion would overflow the stack |

The last two are a deliberate trade: a supervisor can act on a dead process,
but nobody acts on a healthy-looking one that is quietly missing half the tree.

## License

MIT
