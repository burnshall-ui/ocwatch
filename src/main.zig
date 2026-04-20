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
    linux.IN.DELETE_SELF; // watched dir removed

const MAX_PATH = 4096;
const MAX_WATCH_DIRS = 512;
const EVENT_BUF_LEN = 4096;
const DENTS_BUF_LEN = 4096;

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
    defer _ = linux.close(@intCast(ifd));

    var ctx = Context{ .ifd = ifd, .log_fd = log_fd, .map = .{} };

    // Watch dir and all subdirs
    try addWatchRecursive(&ctx, watch_dir);

    // Startup message
    {
        var msg: [512]u8 = undefined;
        const ts = timestamp();
        const line = std.fmt.bufPrint(&msg, "{s}  {s:<12}  watching {s} ({d} dirs) → {s}\n", .{
            &ts, "START", watch_dir, ctx.map.count, log_path,
        }) catch &msg;
        writeLine(&ctx, line);
    }

    // Event loop
    var buf: [EVENT_BUF_LEN]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const n = linux.read(@intCast(ifd), &buf, buf.len);
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
        .NOENT, .ACCES => return,
        else => return,
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
        else => return,
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

            if (ent.type != linux.DT.DIR) continue;
            const name_ptr: [*]const u8 = @ptrCast(&ent.name);
            const name = mem.sliceTo(name_ptr, 0);
            if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) continue;

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

fn handleEvent(ctx: *Context, ev: *const linux.inotify_event) void {
    // Kernel invalidated this wd (after DELETE_SELF, unmount, or rm_watch).
    // Free the slot so the map doesn't grow unbounded and recycled wd numbers
    // don't resolve to a stale path.
    if ((ev.mask & linux.IN.IGNORED) != 0) {
        _ = ctx.map.remove(ev.wd);
        return;
    }

    const is_dir = (ev.mask & linux.IN.ISDIR) != 0;

    // New directory: start watching it
    if (is_dir and (ev.mask & linux.IN.CREATE) != 0) {
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
        return;
    }
    // Other dir events: only DELETE is interesting (let it fall through to log).
    if (is_dir and (ev.mask & linux.IN.DELETE) == 0) return;

    const is_write = (ev.mask & linux.IN.CLOSE_WRITE) != 0 or (ev.mask & linux.IN.MOVED_TO) != 0;
    const is_delete = (ev.mask & linux.IN.DELETE) != 0 or (ev.mask & linux.IN.DELETE_SELF) != 0;
    const is_move_from = (ev.mask & linux.IN.MOVED_FROM) != 0;
    if (!is_write and !is_delete and !is_move_from) return;

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
    if (is_write and name.len > 0) {
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

    var line_buf: [1200]u8 = undefined;
    const ts = timestamp();
    const line = if (extra.len > 0)
        std.fmt.bufPrint(&line_buf, "{s}  {s:<12}  {s}  {s}\n", .{ &ts, event_str, full_path, extra }) catch return
    else
        std.fmt.bufPrint(&line_buf, "{s}  {s:<12}  {s}\n", .{ &ts, event_str, full_path }) catch return;

    writeLine(ctx, line);
}

fn writeLine(ctx: *Context, line: []const u8) void {
    _ = linux.write(@intCast(ctx.log_fd), line.ptr, line.len);
    _ = linux.write(1, line.ptr, line.len); // stdout
}

fn logSimple(ctx: *Context, tag: []const u8, payload: []const u8) void {
    var buf: [MAX_PATH + 64]u8 = undefined;
    const ts = timestamp();
    const line = std.fmt.bufPrint(&buf, "{s}  {s:<12}  {s}\n", .{ &ts, tag, payload }) catch return;
    writeLine(ctx, line);
}

fn writeStr(fd: i32, s: []const u8) void {
    _ = linux.write(@intCast(fd), s.ptr, s.len);
}

fn nameFromEvent(ev: *const linux.inotify_event) []const u8 {
    if (ev.len == 0) return "";
    const base: [*]const u8 = @ptrCast(ev);
    const raw = base[@sizeOf(linux.inotify_event) .. @sizeOf(linux.inotify_event) + ev.len];
    return mem.sliceTo(raw, 0);
}

fn eventStr(mask: u32) []const u8 {
    if (mask & linux.IN.CLOSE_WRITE != 0) return "WRITE";
    if (mask & linux.IN.MOVED_TO != 0) return "RENAME-TO";
    if (mask & linux.IN.MOVED_FROM != 0) return "RENAME-FROM";
    if (mask & linux.IN.DELETE_SELF != 0) return "DELETE-SELF";
    if (mask & linux.IN.DELETE != 0) {
        return if (mask & linux.IN.ISDIR != 0) "DELETE-DIR" else "DELETE";
    }
    if (mask & linux.IN.CREATE != 0) return "CREATE";
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
