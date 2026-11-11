//! Per-user socket server for the TracingInsights desktop app (POSIX:
//! a Unix socket, mode 0600; Windows: pipe_windows.zig, tp-core lane).
//!
//! One client at a time. A listener thread owns accept() and the read side:
//! it splits the stream into lines (≤ protocol.max_line_bytes), checks the
//! first line is `hello` with the token from the token file (re-read on every
//! hello: Electron rewrites it on each start), answers `ready` itself, and
//! queues every later line in a mailbox the app's poll timer drains on the
//! loop thread. A newer connection replaces the old one (an Electron that
//! crashed never says goodbye). Writes come from the loop thread (events,
//! positions, menu actions) and from the listener (`ready`), serialised by a
//! lock.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

pub const version = "0.2.0";
/// protocol.caps: what this pet draws (Electron gates payload fields on it).
pub const caps = protocol.caps;

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

const max_queued_lines = 64;

pub const Status = struct {
    /// A client finished `hello` since the last take().
    connected: bool = false,
    /// The client went away since the last take().
    disconnected: bool = false,
    /// A client is connected now.
    live: bool = false,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    token_path: []const u8,
    pid: u32,

    lock: SpinMutex = .{},
    write_lock: SpinMutex = .{},
    queue: [max_queued_lines][]u8 = undefined,
    queue_len: usize = 0,
    status: Status = .{},
    /// Connection generation; bumps on every accepted client.
    generation: u64 = 0,
    client: ?std.Io.net.Stream = null,
    client_generation: u64 = 0,
    /// Generation whose client finished `hello`.
    hello_generation: u64 = 0,

    /// Loop-thread Io for writes (its own Threaded instance, never the
    /// listener's).
    write_threaded: std.Io.Threaded,

    /// Lines queued since the last call, oldest first; caller frees each
    /// with `allocator`. Returns the connection status delta.
    pub fn take(self: *Server, out: *[max_queued_lines][]u8, out_len: *usize) Status {
        self.lock.lock();
        defer self.lock.unlock();
        @memcpy(out[0..self.queue_len], self.queue[0..self.queue_len]);
        out_len.* = self.queue_len;
        self.queue_len = 0;
        var s = self.status;
        s.live = self.client != null and self.client_generation == self.generation and self.helloDone();
        self.status.connected = false;
        self.status.disconnected = false;
        return s;
    }

    fn helloDone(self: *Server) bool {
        return self.hello_generation == self.generation and self.client != null;
    }

    /// Send one already-encoded line to the current client (after hello).
    /// False when nobody is connected or the write failed.
    pub fn send(self: *Server, line: []const u8) bool {
        self.lock.lock();
        const stream = if (self.client != null and self.helloDone()) self.client.? else null;
        self.lock.unlock();
        const s = stream orelse return false;
        return self.writeAll(s, self.write_threaded.io(), line);
    }

    fn writeAll(self: *Server, stream: std.Io.net.Stream, io: std.Io, line: []const u8) bool {
        self.write_lock.lock();
        defer self.write_lock.unlock();
        var buf: [1024]u8 = undefined;
        var w = stream.writer(io, &buf);
        w.interface.writeAll(line) catch return false;
        w.interface.flush() catch return false;
        return true;
    }

    /// Remove the socket file (quit path). The listener thread is left to
    /// die with the process.
    pub fn shutdown(self: *Server) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        std.Io.Dir.deleteFileAbsolute(threaded.io(), self.socket_path) catch {};
    }

    fn push(self: *Server, generation: u64, line: []const u8) void {
        const copy = self.allocator.dupe(u8, line) catch return;
        self.lock.lock();
        defer self.lock.unlock();
        if (generation != self.generation or self.queue_len >= max_queued_lines) {
            self.allocator.free(copy);
            return;
        }
        self.queue[self.queue_len] = copy;
        self.queue_len += 1;
    }
};

pub const StartError = error{ AlreadyRunning, PathTooLong, ListenFailed, OutOfMemory, Unsupported };

/// Bind the socket and start the listener thread. `AlreadyRunning` when a
/// live pet already answers on the path (one pet per profile).
pub fn start(allocator: std.mem.Allocator, socket_path: []const u8, token_path: []const u8, pid: u32) StartError!*Server {
    if (builtin.os.tag == .windows) return error.Unsupported; // pipe_windows.zig
    if (socket_path.len == 0 or socket_path.len > std.Io.net.UnixAddress.max_len - 1) return error.PathTooLong;
    const server = try allocator.create(Server);
    errdefer allocator.destroy(server);
    server.* = .{
        .allocator = allocator,
        .socket_path = try allocator.dupe(u8, socket_path),
        .token_path = try allocator.dupe(u8, token_path),
        .pid = pid,
        .write_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{}),
    };

    var handshake: Handshake = .{};
    const thread = std.Thread.spawn(.{}, run, .{ server, &handshake }) catch return error.ListenFailed;
    while (handshake.state.load(.acquire) == .pending) std.Thread.yield() catch {};
    switch (handshake.state.load(.acquire)) {
        .listening => {
            thread.detach();
            return server;
        },
        .already_running => {
            thread.join();
            return error.AlreadyRunning;
        },
        else => {
            thread.join();
            return error.ListenFailed;
        },
    }
}

const Handshake = struct {
    state: std.atomic.Value(HandshakeState) = .init(.pending),
};
const HandshakeState = enum(u8) { pending, listening, already_running, failed };

fn run(server: *Server, handshake: *Handshake) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = std.Io.net.UnixAddress.init(server.socket_path) catch {
        handshake.state.store(.failed, .release);
        return;
    };
    // A socket file left by a crashed pet refuses connections: remove it.
    // One that answers belongs to a live pet: this one must exit.
    if (address.connect(io)) |stream| {
        stream.close(io);
        handshake.state.store(.already_running, .release);
        return;
    } else |_| {
        std.Io.Dir.deleteFileAbsolute(io, server.socket_path) catch {};
    }

    var path_z: [std.Io.net.UnixAddress.max_len + 1]u8 = undefined;
    @memcpy(path_z[0..server.socket_path.len], server.socket_path);
    path_z[server.socket_path.len] = 0;
    // Create it 0600 from the start (no window where others could
    // connect), then chmod in case the platform ignores umask for sockets.
    const old_mask = std.c.umask(0o177);
    var listener = address.listen(io, .{ .kernel_backlog = 4 }) catch {
        _ = std.c.umask(old_mask);
        handshake.state.store(.failed, .release);
        return;
    };
    _ = std.c.umask(old_mask);
    defer listener.deinit(io);
    _ = std.c.chmod(@ptrCast(&path_z), 0o600);
    handshake.state.store(.listening, .release);

    while (true) {
        const stream = listener.accept(io) catch continue;
        server.lock.lock();
        // A new client replaces the previous one (closing it ends that
        // reader thread's loop).
        if (server.client) |old| {
            old.shutdown(io, .both) catch {};
        }
        server.generation += 1;
        const generation = server.generation;
        server.client = stream;
        server.client_generation = generation;
        server.lock.unlock();
        const t = std.Thread.spawn(.{}, serveClient, .{ server, stream, generation }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn serveClient(server: *Server, stream: std.Io.net.Stream, generation: u64) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer {
        server.lock.lock();
        if (server.client_generation == generation and server.generation == generation) {
            server.client = null;
            if (server.hello_generation == generation) server.status.disconnected = true;
        }
        server.lock.unlock();
        stream.close(io);
    }

    const buf = server.allocator.alloc(u8, protocol.max_line_bytes + 1) catch return;
    defer server.allocator.free(buf);
    var len: usize = 0;
    var hello = false;
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    while (true) {
        // Whatever has arrived (at least one byte; EndOfStream = closed).
        const data = reader.interface.peekGreedy(1) catch return;
        const n = @min(data.len, buf.len - len);
        @memcpy(buf[len..][0..n], data[0..n]);
        reader.interface.toss(n);
        len += n;
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            const line = std.mem.trimEnd(u8, buf[0..nl], "\r");
            if (line.len > 0) {
                if (!hello) {
                    if (!checkHello(server, io, line)) return;
                    hello = true;
                    server.lock.lock();
                    const current = server.generation == generation;
                    if (current) {
                        server.hello_generation = generation;
                        server.status.connected = true;
                    }
                    server.lock.unlock();
                    if (!current) return;
                    var out: [512]u8 = undefined;
                    const ready = protocol.encode(&out, protocol.Ready{
                        .version = version,
                        .caps = &caps,
                        .pid = server.pid,
                    }) orelse return;
                    if (!server.writeAll(stream, io, ready)) return;
                } else {
                    server.push(generation, line);
                }
            }
            const rest = len - (nl + 1);
            std.mem.copyForwards(u8, buf[0..rest], buf[nl + 1 .. len]);
            len = rest;
        }
        // A line longer than the limit: the peer is broken or hostile.
        if (len > protocol.max_line_bytes) return;
    }
}

fn checkHello(server: *Server, io: std.Io, line: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(server.allocator);
    defer arena.deinit();
    const msg = protocol.parseLine(arena.allocator(), line) catch return false;
    const hello = switch (msg) {
        .hello => |h| h,
        else => return false,
    };
    var token_buf: [256]u8 = undefined;
    const expected = readSmallFile(io, server.token_path, &token_buf) orelse return false;
    if (!protocol.tokenMatches(expected, hello.token)) return false;
    return hello.protocol == protocol.protocol_version;
}

fn readSmallFile(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    if (n == 0 or n == buf.len) return null;
    return buf[0..n];
}
