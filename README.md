# ocwatch

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
ExecStart=/root/.local/bin/ocwatch /root/.openclaw /root/.openclaw/logs/ocwatch.log
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

```sh
systemctl --user enable --now ocwatch
```

## Event types

| Event         | Meaning                                           |
|---------------|---------------------------------------------------|
| `WRITE`       | File closed after write (`IN_CLOSE_WRITE`)        |
| `RENAME-TO`   | File renamed here — openclaw's atomic write pattern |
| `RENAME-FROM` | Source side of a rename                           |
| `DELETE`      | File removed                                      |
| `DELETE-SELF` | Watched directory removed                         |

New subdirectories are picked up automatically at runtime — no restart needed.

## Log format

```
<ISO8601-ms>  <EVENT>       <full-path>  [<size>B]
```

Size is shown for `WRITE` and `RENAME-TO` events via `statx(2)`.

## License

MIT
