// ocwatch — OpenClaw Agent Write Monitor
// Watches a directory tree with inotify and logs write events.
//
// Usage: ocwatch [watch-dir] [log-file]
//   watch-dir  default: /root/.openclaw
//   log-file   default: /root/.openclaw/logs/ocwatch.log

const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

// inotify flags we care about
const WATCH_MASK: u32 =
    linux.IN.CLOSE_WRITE | // file closed after write
    linux.IN.MOVED_TO | // atomic rename (openclaw config pattern)
    linux.IN.MOVED_FROM | // other side of rename
    linux.IN.CREATE | // new file / dir
    linux.IN.DELETE | // deletion
    linux.IN.DELETE_SELF | // watched dir removed
    linux.IN.MOVE_SELF; // watched dir moved — our cached path is now a lie

const MAX_PATH = 4096;
const MAX_WATCH_DIRS = 512;
const EVENT_BUF_LEN = 4096;
const DENTS_BUF_LEN = 4096;

// A log line has to hold the longest path we are willing to accept, plus the
// timestamp, the tag and the size suffix. Sizing it below MAX_PATH means long
// paths fail to format and the event disappears without a trace — see the
// drift guard at the bottom of this file.
const MAX_LOG_LINE = MAX_PATH + 128;
// The startup line names two paths: the watch root and the log file.
const MAX_START_LINE = 2 * MAX_PATH + 128;

const AddResult = enum { added, duplicate, full };

// Maps inotify watch descriptor → directory path
const WdMap = struct {
    wds: [MAX_WATCH_DIRS]i32 = undefined,
    paths: [MAX_WATCH_DIRS][MAX_PATH]u8 = undefined,
    path_lens: [MAX_WATCH_DIRS]usize = [_]usize{0} ** MAX_WATCH_DIRS,
    count: usize = 0,

    fn add(self: *WdMap, wd: i32, path: []const u8) AddResult {
        for (0..self.count) |i| {
            if (self.wds[i] == wd) return .duplicate;
        }
        if (self.count >= MAX_WATCH_DIRS) return .full;
        const i = self.count;
        self.wds[i] = wd;
        const len = @min(path.len, MAX_PATH - 1);
        @memcpy(self.paths[i][0..len], path[0..len]);
        self.path_lens[i] = len;
        self.count += 1;
        return .added;
    }

    fn remove(self: *WdMap, wd: i32) bool {
        for (0..self.count) |i| {
            if (self.wds[i] == wd) {
                const last = self.count - 1;
                if (i != last) {
                    self.wds[i] = self.wds[last];
                    self.paths[i] = self.paths[last];
                    self.path_lens[i] = self.path_lens[last];
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }

    fn lookup(self: *const WdMap, wd: i32) ?[]const u8 {
        for (0..self.count) |i| {
            if (self.wds[i] == wd) return self.paths[i][0..self.path_lens[i]];
        }
        return null;
    }
};

const Context = struct {
    ifd: i32,
    log_fd: i32,
    map: WdMap,
    // The tree we were asked to watch. Kept so a rebuild can re-scan it.
    root: []const u8,
    // Set by events that invalidate the wd→path map. Acted on once per read
    // batch rather than inline: rebuilding mid-batch would invalidate the very
    // descriptors the remaining events in the buffer still refer to, and an
    // intra-tree rename delivers MOVED_FROM and MOVED_TO together anyway.
    needs_rebuild: bool = false,
};

pub fn main(io: std.process.Init.Minimal) !void {
    _ = io.environ;
    var args = std.process.Args.Iterator.init(io.args);
    _ = args.next(); // skip argv[0]
    const watch_dir = args.next() orelse "/root/.openclaw";
    const log_path = args.next() orelse "/root/.openclaw/logs/ocwatch.log";

    // Open log file for append (create if needed)
    var log_path_z: [MAX_PATH]u8 = undefined;
    if (log_path.len >= MAX_PATH) return error.PathTooLong;
    @memcpy(log_path_z[0..log_path.len], log_path);
    log_path_z[log_path.len] = 0;

    // Best-effort: create the log file's parent directory tree so the default
    // `<watch-dir>/logs/ocwatch.log` works on a fresh install. Errors are
    // ignored — if mkdir fails for a real reason, open() below will surface it.
    if (mem.lastIndexOfScalar(u8, log_path, '/')) |slash| {
        if (slash > 0) mkdirP(log_path[0..slash]);
    }

    const log_fd_rc = linux.open(
        @ptrCast(&log_path_z),
        linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
        0o644,
    );
    const log_fd: i32 = switch (linux.errno(log_fd_rc)) {
        .SUCCESS => @intCast(log_fd_rc),
        else => |err| {
            writeStr(2, "ocwatch: cannot open log file: ");
            writeStr(2, @tagName(err));
            writeStr(2, "\n");
            return error.OpenLog;
        },
    };
    defer _ = linux.close(@intCast(log_fd));

    // Init inotify
    const ifd_rc = linux.inotify_init1(linux.IN.CLOEXEC);
    const ifd: i32 = switch (linux.errno(ifd_rc)) {
        .SUCCESS => @intCast(ifd_rc),
        else => |err| {
            writeStr(2, "ocwatch: inotify_init1 failed: ");
            writeStr(2, @tagName(err));
            writeStr(2, "\n");
            return error.InotifyInit;
        },
    };
    var ctx = Context{ .ifd = ifd, .log_fd = log_fd, .map = .{}, .root = watch_dir };
    // Deliberately on ctx.ifd, not the local: a rebuild swaps the instance out.
    defer _ = linux.close(@intCast(ctx.ifd));

    // Watch dir and all subdirs
    try addWatchRecursive(&ctx, watch_dir);

    // A watcher holding no watches blocks forever on an empty inotify fd. The
    // process stays alive, the supervisor reports `active (running)`, and
    // nothing is ever observed — broken in the way that is hardest to notice.
    // Exiting non-zero is the only honest option: it lets Restart= do its job.
    if (ctx.map.count == 0) {
        logSimple(&ctx, "NO-WATCH", watch_dir);
        writeStr(2, "ocwatch: cannot watch anything under ");
        writeStr(2, watch_dir);
        writeStr(2, "\n");
        return error.NoWatchableRoot;
    }

    // Startup message
    {
        var msg: [MAX_START_LINE]u8 = undefined;
        const ts = timestamp();
        const line = std.fmt.bufPrint(&msg, "{s}  {s:<15}  watching {s} ({d} dirs) → {s}\n", .{
            &ts, "START", watch_dir, ctx.map.count, log_path,
        }) catch return error.StartupLineFormat;
        writeLine(&ctx, line);
    }

    // Event loop
    var buf: [EVENT_BUF_LEN]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const n = linux.read(@intCast(ctx.ifd), &buf, buf.len);
        const nbytes: usize = switch (linux.errno(n)) {
            .SUCCESS => n,
            .INTR => continue,
            else => |err| {
                writeStr(2, "ocwatch: read failed: ");
                writeStr(2, @tagName(err));
                writeStr(2, "\n");
                return error.ReadFailed;
            },
        };
        if (nbytes == 0) return error.UnexpectedEof;

        var offset: usize = 0;
        while (offset < nbytes) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
            handleEvent(&ctx, ev);
            offset += @sizeOf(linux.inotify_event) + ev.len;
        }

        // Coalesced to once per batch: a single directory rename raises three
        // separate invalidating events (MOVED_FROM and MOVED_TO at the parent,
        // MOVE_SELF at the directory itself), and one re-scan settles all of
        // them. If the root itself was what moved away, the re-scan finds
        // nothing and the check below turns that into a clean exit.
        if (ctx.needs_rebuild) {
            ctx.needs_rebuild = false;
            rebuildWatches(&ctx);
        }

        // The last watch is gone — the root was deleted out from under us.
        // Nothing can ever arrive on this fd again, so staying in the loop
        // would be the same silent blindness as starting without a root.
        if (ctx.map.count == 0) {
            logSimple(&ctx, "WATCH-LOST", "last watch dropped; exiting to be restarted");
            return error.AllWatchesLost;
        }
    }
}

fn addWatchRecursive(ctx: *Context, path: []const u8) !void {
    if (path.len >= MAX_PATH) {
        logSimple(ctx, "PATH-TOO-LONG", path);
        return;
    }
    var path_z: [MAX_PATH]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const wd_rc = linux.inotify_add_watch(@intCast(ctx.ifd), @ptrCast(&path_z), WATCH_MASK);
    const wd: i32 = switch (linux.errno(wd_rc)) {
        .SUCCESS => @intCast(wd_rc),
        // Benign: dir vanished mid-walk or we lack search permission on a single
        // entry. These happen routinely with concurrent agents and don't merit a log line.
        .NOENT, .ACCES => return,
        else => |err| {
            logErr(ctx, "WATCH-ERR", err, path);
            return;
        },
    };

    switch (ctx.map.add(wd, path)) {
        .added => {},
        .duplicate => return, // already watching this dir, race already handled
        .full => {
            logSimple(ctx, "WATCH-LIMIT", path);
            _ = linux.inotify_rm_watch(@intCast(ctx.ifd), wd);
            return;
        },
    }

    // Open directory and iterate entries
    const dir_fd_rc = linux.open(
        @ptrCast(&path_z),
        linux.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
        0,
    );
    const dir_fd: i32 = switch (linux.errno(dir_fd_rc)) {
        .SUCCESS => @intCast(dir_fd_rc),
        .NOENT, .ACCES => return,
        else => |err| {
            logErr(ctx, "OPEN-ERR", err, path);
            return;
        },
    };
    defer _ = linux.close(@intCast(dir_fd));

    var dents_buf: [DENTS_BUF_LEN]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const nread = linux.getdents64(@intCast(dir_fd), &dents_buf, dents_buf.len);
        switch (linux.errno(nread)) {
            .SUCCESS => {},
            else => break,
        }
        if (nread == 0) break;

        var bpos: usize = 0;
        while (bpos < nread) {
            const ent: *const linux.dirent64 = @ptrCast(@alignCast(&dents_buf[bpos]));
            bpos += ent.reclen;

            const name_ptr: [*:0]const u8 = @ptrCast(&ent.name);
            const name = mem.sliceTo(name_ptr, 0);
            if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) continue;

            // Some filesystems (older NFS, certain FUSE backends) return DT_UNKNOWN
            // and force a stat. Fall back to statx in that case so we don't silently
            // skip subdirs.
            const is_subdir = switch (ent.type) {
                linux.DT.DIR => true,
                linux.DT.UNKNOWN => isDirAt(dir_fd, name_ptr),
                else => false,
            };
            if (!is_subdir) continue;

            // Skip hidden dirs that aren't openclaw-related
            if (name.len > 0 and name[0] == '.') {
                if (!mem.startsWith(u8, name, ".openclaw") and
                    !mem.eql(u8, name, ".dreams") and
                    !mem.eql(u8, name, ".clawhub") and
                    !mem.eql(u8, name, ".openclaw-wiki"))
                {
                    continue;
                }
            }

            var sub: [MAX_PATH]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub, "{s}/{s}", .{ path, name }) catch {
                logSimple(ctx, "PATH-TOO-LONG", path);
                continue;
            };
            try addWatchRecursive(ctx, sub_path);
        }
    }
}

// Drop every watch and re-scan the tree from the root.
//
// inotify watches are bound to the inode, not the path, so once a directory
// moves there is no way to repair the wd→path map in place: the descriptors
// that need fixing are exactly the ones whose new location we cannot derive.
// Starting a fresh inotify instance is both simpler and stricter than removing
// watches one by one — it discards any IGNORED events the teardown would
// otherwise deliver into the middle of our own event stream.
//
// This is also the documented response to a queue overflow: after events are
// lost, the tree state on record is unknown and only a re-scan restores it.
fn rebuildWatches(ctx: *Context) void {
    // Open the replacement before dropping the old one, so a failure here
    // leaves us degraded but still watching rather than blind.
    const fresh_rc = linux.inotify_init1(linux.IN.CLOEXEC);
    const fresh: i32 = switch (linux.errno(fresh_rc)) {
        .SUCCESS => @intCast(fresh_rc),
        else => |err| {
            logErr(ctx, "REBUILD-ERR", err, ctx.root);
            return;
        },
    };

    _ = linux.close(@intCast(ctx.ifd));
    ctx.ifd = fresh;
    ctx.map.count = 0;
    addWatchRecursive(ctx, ctx.root) catch {};

    var payload: [MAX_PATH + 64]u8 = undefined;
    const p = std.fmt.bufPrint(&payload, "{d} dirs re-scanned under {s}", .{ ctx.map.count, ctx.root }) catch ctx.root;
    logSimple(ctx, "REBUILD", p);
}

fn handleEvent(ctx: *Context, ev: *const linux.inotify_event) void {
    // Kernel invalidated this wd (after DELETE_SELF, unmount, or rm_watch).
    // Free the slot so the map doesn't grow unbounded and recycled wd numbers
    // don't resolve to a stale path.
    if ((ev.mask & linux.IN.IGNORED) != 0) {
        _ = ctx.map.remove(ev.wd);
        return;
    }

    // Kernel queue overflowed (fs.inotify.max_queued_events exceeded). Events
    // were lost — log so the gap in the trace is visible to whoever reads it.
    // Among the lost events there may have been directory creations we never
    // got to watch, so the map can no longer be trusted either.
    if ((ev.mask & linux.IN.Q_OVERFLOW) != 0) {
        logSimple(ctx, "Q-OVERFLOW", "kernel inotify queue exceeded; events lost");
        ctx.needs_rebuild = true;
        return;
    }

    // This watched directory was moved. The kernel keeps delivering its events
    // wherever it went — including clean out of our tree — and every path we
    // hold for it and its children now names the wrong place.
    if ((ev.mask & linux.IN.MOVE_SELF) != 0) {
        if (ctx.map.lookup(ev.wd)) |moved| logSimple(ctx, "MOVE-SELF", moved);
        ctx.needs_rebuild = true;
        return;
    }

    const is_dir = (ev.mask & linux.IN.ISDIR) != 0;

    if (is_dir) {
        if ((ev.mask & (linux.IN.MOVED_TO | linux.IN.MOVED_FROM)) != 0) {
            // A subtree arrived or left whole. Unlike CREATE this cannot be
            // handled incrementally: an arriving directory brings its existing
            // contents with it, and when it came from inside the tree its
            // watches already exist under their former paths. Re-scan, and let
            // the move itself fall through to be logged.
            ctx.needs_rebuild = true;
        } else if ((ev.mask & linux.IN.CREATE) != 0) {
            // A newly created directory is empty by definition, so one watch
            // is enough and a full re-scan would be wasted work.
            if (ctx.map.lookup(ev.wd)) |parent| {
                const name = nameFromEvent(ev);
                if (name.len > 0) {
                    var sub: [MAX_PATH]u8 = undefined;
                    const sub_path = std.fmt.bufPrint(&sub, "{s}/{s}", .{ parent, name }) catch {
                        logSimple(ctx, "PATH-TOO-LONG", parent);
                        return;
                    };
                    addWatchRecursive(ctx, sub_path) catch {};
                }
            }
        } else if ((ev.mask & (linux.IN.DELETE | linux.IN.DELETE_SELF)) == 0) {
            // Anything else about a directory is not worth a line.
            return;
        }
    }

    const is_write = (ev.mask & linux.IN.CLOSE_WRITE) != 0 or (ev.mask & linux.IN.MOVED_TO) != 0;
    const is_delete = (ev.mask & linux.IN.DELETE) != 0 or (ev.mask & linux.IN.DELETE_SELF) != 0;
    const is_move_from = (ev.mask & linux.IN.MOVED_FROM) != 0;
    // CREATE is deliberately not logged for files — they are reported on
    // CLOSE_WRITE instead, and logging both would double every write. A
    // directory has no CLOSE_WRITE, so without this it would appear in the
    // trail only once something was written inside it.
    const is_new_dir = is_dir and (ev.mask & linux.IN.CREATE) != 0;
    if (!is_write and !is_delete and !is_move_from and !is_new_dir) return;

    const dir_path = ctx.map.lookup(ev.wd) orelse return;
    const name = nameFromEvent(ev);
    const event_str = eventStr(ev.mask);

    // Build full path
    var path_buf: [MAX_PATH]u8 = undefined;
    const full_path = if (name.len > 0)
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch {
            logSimple(ctx, "PATH-TOO-LONG", dir_path);
            return;
        }
    else
        dir_path;

    // File size for writes (best-effort via statx)
    var extra_buf: [32]u8 = undefined;
    var extra: []const u8 = "";
    // Directories are excluded: statx would happily report the 4096-byte size
    // of the directory entry itself, which means nothing to a reader.
    if (is_write and !is_dir and name.len > 0) {
        var path_z: [MAX_PATH]u8 = undefined;
        if (full_path.len < MAX_PATH) {
            @memcpy(path_z[0..full_path.len], full_path);
            path_z[full_path.len] = 0;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(
                linux.AT.FDCWD,
                @ptrCast(&path_z),
                0,
                linux.STATX{ .SIZE = true },
                &stx,
            );
            if (linux.errno(rc) == .SUCCESS) {
                extra = std.fmt.bufPrint(&extra_buf, "[{d}B]", .{stx.size}) catch "";
            }
        }
    }

    var line_buf: [MAX_LOG_LINE]u8 = undefined;
    const ts = timestamp();
    const line = if (extra.len > 0)
        std.fmt.bufPrint(&line_buf, "{s}  {s:<15}  {s}  {s}\n", .{ &ts, event_str, full_path, extra }) catch {
            logOverflow(ctx, event_str, full_path);
            return;
        }
    else
        std.fmt.bufPrint(&line_buf, "{s}  {s:<15}  {s}\n", .{ &ts, event_str, full_path }) catch {
            logOverflow(ctx, event_str, full_path);
            return;
        };

    writeLine(ctx, line);
}

fn writeLine(ctx: *Context, line: []const u8) void {
    _ = linux.write(@intCast(ctx.log_fd), line.ptr, line.len);
    _ = linux.write(1, line.ptr, line.len); // stdout
}

fn logSimple(ctx: *Context, tag: []const u8, payload: []const u8) void {
    var buf: [MAX_LOG_LINE]u8 = undefined;
    const ts = timestamp();
    const line = std.fmt.bufPrint(&buf, "{s}  {s:<15}  {s}\n", .{ &ts, tag, payload }) catch return;
    writeLine(ctx, line);
}

// MAX_LOG_LINE is sized so this cannot trigger for any path the kernel can
// hand us. It exists because the previous code answered an unformattable line
// with a bare `catch return`, which is how writes below deep paths went
// missing with nothing in the log to suggest anything had been lost. An event
// we cannot render in full is still an event worth admitting to.
fn logOverflow(ctx: *Context, event_str: []const u8, path: []const u8) void {
    var payload: [320]u8 = undefined;
    const head = path[0..@min(path.len, 200)];
    const p = std.fmt.bufPrint(&payload, "{s} ({d} bytes, truncated): {s}", .{ event_str, path.len, head }) catch return;
    logSimple(ctx, "LINE-OVERFLOW", p);
}

fn writeStr(fd: i32, s: []const u8) void {
    _ = linux.write(@intCast(fd), s.ptr, s.len);
}

fn logErr(ctx: *Context, tag: []const u8, err: linux.E, path: []const u8) void {
    var buf: [MAX_LOG_LINE]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{s}: {s}", .{ @tagName(err), path }) catch path;
    logSimple(ctx, tag, payload);
}

fn isDirAt(dir_fd: i32, name: [*:0]const u8) bool {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(
        @intCast(dir_fd),
        @ptrCast(name),
        linux.AT.SYMLINK_NOFOLLOW,
        linux.STATX{ .TYPE = true },
        &stx,
    );
    if (linux.errno(rc) != .SUCCESS) return false;
    return (stx.mode & linux.S.IFMT) == linux.S.IFDIR;
}

fn mkdirP(path: []const u8) void {
    if (path.len == 0 or path.len >= MAX_PATH) return;
    var buf: [MAX_PATH]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    // mkdir each '/'-prefix in turn; EEXIST and other errors are ignored — the
    // subsequent open() of the log file is the real signal.
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            buf[i] = 0;
            _ = linux.mkdir(@ptrCast(&buf), 0o755);
            buf[i] = '/';
        }
    }
    _ = linux.mkdir(@ptrCast(&buf), 0o755);
}

fn nameFromEvent(ev: *const linux.inotify_event) []const u8 {
    if (ev.len == 0) return "";
    const base: [*]const u8 = @ptrCast(ev);
    const raw = base[@sizeOf(linux.inotify_event) .. @sizeOf(linux.inotify_event) + ev.len];
    return mem.sliceTo(raw, 0);
}

fn eventStr(mask: u32) []const u8 {
    const isdir = mask & linux.IN.ISDIR != 0;
    if (mask & linux.IN.CLOSE_WRITE != 0) return "WRITE";
    if (mask & linux.IN.MOVED_TO != 0) return if (isdir) "RENAME-TO-DIR" else "RENAME-TO";
    if (mask & linux.IN.MOVED_FROM != 0) return if (isdir) "RENAME-FROM-DIR" else "RENAME-FROM";
    if (mask & linux.IN.MOVE_SELF != 0) return "MOVE-SELF";
    if (mask & linux.IN.DELETE_SELF != 0) return "DELETE-SELF";
    if (mask & linux.IN.DELETE != 0) return if (isdir) "DELETE-DIR" else "DELETE";
    if (mask & linux.IN.CREATE != 0) return if (isdir) "CREATE-DIR" else "CREATE";
    return "UNKNOWN";
}

fn timestamp() [23]u8 {
    var buf: [23]u8 = [_]u8{' '} ** 23;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);

    const secs: u64 = @intCast(ts.sec);
    const ms: u64 = @intCast(@divTrunc(ts.nsec, 1_000_000));

    const ep = std.time.epoch;
    const es = ep.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        ms,
    }) catch {};
    return buf;
}

// ──────────────────────────────────────────────
// Tests
//
// eventStr is the only branch-heavy pure function here; everything else is
// syscall-bound and covered by the integration check in CI instead.
// ──────────────────────────────────────────────

const testing = std.testing;

test "eventStr names every mask we subscribe to" {
    try testing.expectEqualStrings("WRITE", eventStr(linux.IN.CLOSE_WRITE));
    try testing.expectEqualStrings("RENAME-TO", eventStr(linux.IN.MOVED_TO));
    try testing.expectEqualStrings("RENAME-FROM", eventStr(linux.IN.MOVED_FROM));
    try testing.expectEqualStrings("DELETE-SELF", eventStr(linux.IN.DELETE_SELF));
    try testing.expectEqualStrings("DELETE", eventStr(linux.IN.DELETE));
    try testing.expectEqualStrings("CREATE", eventStr(linux.IN.CREATE));
}

test "eventStr separates directory events from file events" {
    try testing.expectEqualStrings("DELETE-DIR", eventStr(linux.IN.DELETE | linux.IN.ISDIR));
    try testing.expectEqualStrings("DELETE", eventStr(linux.IN.DELETE));
    try testing.expectEqualStrings("CREATE-DIR", eventStr(linux.IN.CREATE | linux.IN.ISDIR));
    try testing.expectEqualStrings("CREATE", eventStr(linux.IN.CREATE));
    // Directory moves are the events that force a rebuild, so a reader has to
    // be able to tell them apart from an ordinary file rename at a glance.
    try testing.expectEqualStrings("RENAME-TO-DIR", eventStr(linux.IN.MOVED_TO | linux.IN.ISDIR));
    try testing.expectEqualStrings("RENAME-TO", eventStr(linux.IN.MOVED_TO));
    try testing.expectEqualStrings("RENAME-FROM-DIR", eventStr(linux.IN.MOVED_FROM | linux.IN.ISDIR));
    try testing.expectEqualStrings("RENAME-FROM", eventStr(linux.IN.MOVED_FROM));
}

test "eventStr names a watched directory moving out from under us" {
    // The kernel does not set ISDIR on MOVE_SELF, the same way it does not for
    // DELETE_SELF — the subject of the event is the watch itself.
    try testing.expectEqualStrings("MOVE-SELF", eventStr(linux.IN.MOVE_SELF));
    try testing.expectEqualStrings("DELETE-SELF", eventStr(linux.IN.DELETE_SELF));
}

test "eventStr prefers the write over co-occurring bits" {
    // The kernel can set several bits at once; a completed write is the most
    // specific thing we can say about the file, so it has to win.
    const combined = linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.ISDIR;
    try testing.expectEqualStrings("WRITE", eventStr(combined));
}

test "eventStr does not invent a name for masks we ignore" {
    try testing.expectEqualStrings("UNKNOWN", eventStr(0));
    try testing.expectEqualStrings("UNKNOWN", eventStr(linux.IN.ACCESS));
    try testing.expectEqualStrings("UNKNOWN", eventStr(linux.IN.OPEN));
}

test "WATCH_MASK subscribes to exactly the events eventStr can name" {
    // Drift guard: adding a bit to WATCH_MASK without teaching eventStr about
    // it would log the event as UNKNOWN.
    const named = [_]u32{
        linux.IN.CLOSE_WRITE,
        linux.IN.MOVED_TO,
        linux.IN.MOVED_FROM,
        linux.IN.CREATE,
        linux.IN.DELETE,
        linux.IN.DELETE_SELF,
        linux.IN.MOVE_SELF,
    };
    var covered: u32 = 0;
    for (named) |bit| {
        try testing.expect(!std.mem.eql(u8, "UNKNOWN", eventStr(bit)));
        covered |= bit;
    }
    try testing.expectEqual(WATCH_MASK, covered);
}

test "the log line buffer can hold the longest event we accept" {
    // Drift guard: a line is timestamp + separator + padded tag + separator +
    // path + separator + size suffix + newline. Shrinking MAX_LOG_LINE below
    // that — or raising MAX_PATH without it — brings back the silent drop of
    // events whose path is longer than the buffer.
    const longest_tag = "RENAME-FROM-DIR".len;
    const size_suffix = "[18446744073709551615B]".len;
    const worst_case = 23 + 2 + longest_tag + 2 + MAX_PATH + 2 + size_suffix + 1;
    try testing.expect(MAX_LOG_LINE >= worst_case);

    // The tag column is padded to this width. A longer tag does not truncate,
    // it shoves the path column out of alignment for that one line.
    try testing.expect(longest_tag <= 15);

    // The startup line carries the watch root and the log path together.
    try testing.expect(MAX_START_LINE >= 23 + 2 + longest_tag + 2 + 2 * MAX_PATH + 64);
}

test "timestamp has the fixed width the log format relies on" {
    const ts = timestamp();
    try testing.expectEqual(@as(usize, 23), ts.len);
    // YYYY-MM-DDTHH:MM:SS.mmm
    try testing.expectEqual(@as(u8, '-'), ts[4]);
    try testing.expectEqual(@as(u8, '-'), ts[7]);
    try testing.expectEqual(@as(u8, 'T'), ts[10]);
    try testing.expectEqual(@as(u8, ':'), ts[13]);
    try testing.expectEqual(@as(u8, ':'), ts[16]);
    try testing.expectEqual(@as(u8, '.'), ts[19]);
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 22 }) |i| {
        try testing.expect(ts[i] >= '0' and ts[i] <= '9');
    }
}
