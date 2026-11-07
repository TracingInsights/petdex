//! Per-user named-pipe server for the TracingInsights desktop app
//! (Windows). The POSIX twin is ipc.zig; this file mirrors its public API
//! (`start`, `Server.take`, `Server.send`, `Server.shutdown`, `Status`) so
//! main.zig can pick either at comptime.
//!
//! Pipe name: `\\.\pipe\tracinginsights-pet-<sha256(userData) hex, 16>`,
//! the same rule as nativeSocketPath() in desktop/src/pets/native-protocol.mjs
//! (Electron passes the name with `--socket`; `pipeName` recomputes it for
//! checks and tests).
//!
//! - Only the current user may open it: every instance carries a DACL with a
//!   single allow entry for the process token's user SID, and remote
//!   clients are rejected (PIPE_REJECT_REMOTE_CLIENTS).
//! - One pet per profile: the first instance is created with
//!   FILE_FLAG_FIRST_PIPE_INSTANCE; if the name already exists another pet
//!   owns it (`error.AlreadyRunning`). Windows removes a pipe with its last
//!   handle, so a crashed pet never leaves a stale name behind.
//! - Same protocol as ipc.zig: the first line must be `hello` with the token
//!   from the token file (re-read on every hello), answered with `ready`;
//!   later lines go to a mailbox the loop thread drains with `take`. A newer
//!   client replaces the old one.
//! - All pipe I/O is overlapped: a synchronous pipe handle serialises reads
//!   and writes, so a pending ReadFile would block every WriteFile.
//!
//! Compile-checked on Linux with
//! `zig test -target x86_64-windows --test-no-exec src/pipe_windows.zig`.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const ipc = @import("ipc.zig");

pub const Status = ipc.Status;
pub const version = ipc.version;
pub const caps = ipc.caps;

const max_queued_lines = 64;
const pipe_prefix = "\\\\.\\pipe\\tracinginsights-pet-";
pub const pipe_name_len = pipe_prefix.len + 16;

/// `\\.\pipe\tracinginsights-pet-<hash>` for this userData directory.
pub fn pipeName(buf: *[pipe_name_len]u8, user_data_dir: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(user_data_dir, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    @memcpy(buf[0..pipe_prefix.len], pipe_prefix);
    @memcpy(buf[pipe_prefix.len..], &hex);
    return buf;
}

/// A pipe name we would serve: our prefix + 16 lowercase hex digits.
pub fn pipeNameOk(name: []const u8) bool {
    if (name.len != pipe_name_len or !std.mem.startsWith(u8, name, pipe_prefix)) return false;
    for (name[pipe_prefix.len..]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

// ------------------------------------------------------------ Win32 API

const win = std.os.windows;
const HANDLE = win.HANDLE;
const BOOL = win.BOOL;

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?HANDLE = null,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const PIPE_TYPE_BYTE: u32 = 0;
const PIPE_READMODE_BYTE: u32 = 0;
const PIPE_WAIT: u32 = 0;
const PIPE_REJECT_REMOTE_CLIENTS: u32 = 0x00000008;
const PIPE_UNLIMITED_INSTANCES: u32 = 255;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const INFINITE: u32 = 0xFFFFFFFF;
const WAIT_OBJECT_0: u32 = 0;
const TOKEN_QUERY: u32 = 0x0008;
const TOKEN_USER_CLASS: u32 = 1; // TokenUser
const SECURITY_DESCRIPTOR_REVISION: u32 = 1;
const ACL_REVISION: u32 = 2;
const FILE_ALL_ACCESS: u32 = 0x001F01FF;
const pipe_buffer_bytes: u32 = 64 * 1024;

const ERROR_ACCESS_DENIED: u32 = 5;
const ERROR_PIPE_CONNECTED: u32 = 535;
const ERROR_IO_PENDING: u32 = 997;

extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: u32, pipe_mode: u32, max_instances: u32, out_size: u32, in_size: u32, timeout_ms: u32, sa: ?*SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(file: HANDLE, buf: [*]u8, len: u32, read: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, len: u32, written: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(file: HANDLE, overlapped: *OVERLAPPED, transferred: *u32, wait: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CreateEventW(sa: ?*SECURITY_ATTRIBUTES, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(file: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "advapi32" fn OpenProcessToken(process: HANDLE, access: u32, token: *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(token: HANDLE, class: u32, info: ?*anyopaque, len: u32, ret_len: *u32) callconv(.winapi) BOOL;
extern "advapi32" fn GetLengthSid(sid: *anyopaque) callconv(.winapi) u32;
extern "advapi32" fn InitializeSecurityDescriptor(sd: *anyopaque, revision: u32) callconv(.winapi) BOOL;
extern "advapi32" fn InitializeAcl(acl: *anyopaque, len: u32, revision: u32) callconv(.winapi) BOOL;
extern "advapi32" fn AddAccessAllowedAce(acl: *anyopaque, revision: u32, mask: u32, sid: *anyopaque) callconv(.winapi) BOOL;
extern "advapi32" fn SetSecurityDescriptorDacl(sd: *anyopaque, present: BOOL, acl: ?*anyopaque, defaulted: BOOL) callconv(.winapi) BOOL;

fn ok(b: BOOL) bool {
    return b.toBool();
}

/// Security attributes allowing only the current user. The buffers live in
/// the server (they must outlive every CreateNamedPipeW call).
const UserOnly = struct {
    token_user: [256]u8 align(8) = undefined,
    sd: [64]u8 align(8) = undefined,
    acl: [512]u8 align(8) = undefined,
    sa: SECURITY_ATTRIBUTES = undefined,

    fn init(self: *UserOnly) bool {
        var token: HANDLE = undefined;
        if (!ok(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))) return false;
        defer win.CloseHandle(token);
        var len: u32 = 0;
        if (!ok(GetTokenInformation(token, TOKEN_USER_CLASS, &self.token_user, self.token_user.len, &len))) return false;
        // TOKEN_USER { SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes } }
        const sid: *anyopaque = @as(*const *anyopaque, @ptrCast(&self.token_user)).*;
        // sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) + sid
        const acl_len: u32 = 8 + 8 + GetLengthSid(sid);
        if (acl_len > self.acl.len) return false;
        if (!ok(InitializeAcl(&self.acl, acl_len, ACL_REVISION))) return false;
        if (!ok(AddAccessAllowedAce(&self.acl, ACL_REVISION, FILE_ALL_ACCESS, sid))) return false;
        if (!ok(InitializeSecurityDescriptor(&self.sd, SECURITY_DESCRIPTOR_REVISION))) return false;
        if (!ok(SetSecurityDescriptorDacl(&self.sd, .TRUE, &self.acl, .FALSE))) return false;
        self.sa = .{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = &self.sd, .bInheritHandle = .FALSE };
        return true;
    }
};

// --------------------------------------------------------------- server

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    pipe_name_w: [:0]const u16,
    token_path: []const u8,
    pid: u32,
    security: UserOnly = .{},

    lock: SpinMutex = .{},
    /// Held for the whole of every write and while a client handle closes,
    /// so a write never lands on a closed (or reused) handle.
    write_lock: SpinMutex = .{},
    write_event: HANDLE,
    queue: [max_queued_lines][]u8 = undefined,
    queue_len: usize = 0,
    status: Status = .{},
    generation: u64 = 0,
    hello_generation: u64 = 0,
    client: ?HANDLE = null,

    /// Lines queued since the last call, oldest first; caller frees each
    /// with `allocator`. Returns the connection status delta.
    pub fn take(self: *Server, out: *[max_queued_lines][]u8, out_len: *usize) Status {
        self.lock.lock();
        defer self.lock.unlock();
        @memcpy(out[0..self.queue_len], self.queue[0..self.queue_len]);
        out_len.* = self.queue_len;
        self.queue_len = 0;
        var s = self.status;
        s.live = self.client != null and self.hello_generation == self.generation;
        self.status.connected = false;
        self.status.disconnected = false;
        return s;
    }

    /// Send one already-encoded line to the current client (after hello).
    pub fn send(self: *Server, line: []const u8) bool {
        self.write_lock.lock();
        defer self.write_lock.unlock();
        self.lock.lock();
        const handle = if (self.hello_generation == self.generation) self.client else null;
        self.lock.unlock();
        return writeAll(self, handle orelse return false, line);
    }

    /// Drop the client (quit path). The listener thread dies with the
    /// process; the pipe name goes with the last handle.
    pub fn shutdown(self: *Server) void {
        self.lock.lock();
        const handle = self.client;
        self.lock.unlock();
        if (handle) |h| _ = CancelIoEx(h, null);
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

/// Caller holds `write_lock`.
fn writeAll(server: *Server, handle: HANDLE, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        var ov: OVERLAPPED = .{ .hEvent = server.write_event };
        _ = ResetEvent(server.write_event);
        const chunk: u32 = @intCast(@min(rest.len, pipe_buffer_bytes));
        var written: u32 = 0;
        if (!ok(WriteFile(handle, rest.ptr, chunk, null, &ov))) {
            if (GetLastError() != ERROR_IO_PENDING) return false;
        }
        if (!ok(GetOverlappedResult(handle, &ov, &written, .TRUE))) return false;
        if (written == 0) return false;
        rest = rest[written..];
    }
    return true;
}

pub const StartError = error{ AlreadyRunning, PathTooLong, ListenFailed, OutOfMemory, Unsupported };

/// Create the first pipe instance and start the listener thread.
/// `socket_path` is the pipe name Electron passed with `--socket`.
pub fn start(allocator: std.mem.Allocator, socket_path: []const u8, token_path: []const u8, pid: u32) StartError!*Server {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (!pipeNameOk(socket_path)) return error.PathTooLong;
    const server = try allocator.create(Server);
    errdefer allocator.destroy(server);
    const name_w = std.unicode.wtf8ToWtf16LeAllocZ(allocator, socket_path) catch return error.OutOfMemory;
    errdefer allocator.free(name_w);
    server.* = .{
        .allocator = allocator,
        .pipe_name_w = name_w,
        .token_path = try allocator.dupe(u8, token_path),
        .pid = pid,
        .write_event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.ListenFailed,
    };
    if (!server.security.init()) return error.ListenFailed;

    const first = createInstance(server, true) catch |err| return err;
    const thread = std.Thread.spawn(.{}, run, .{ server, first }) catch {
        win.CloseHandle(first);
        return error.ListenFailed;
    };
    thread.detach();
    return server;
}

fn createInstance(server: *Server, first: bool) StartError!HANDLE {
    const open_mode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (if (first) FILE_FLAG_FIRST_PIPE_INSTANCE else 0);
    const pipe_mode = PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS;
    const h = CreateNamedPipeW(server.pipe_name_w.ptr, open_mode, pipe_mode, PIPE_UNLIMITED_INSTANCES, pipe_buffer_bytes, pipe_buffer_bytes, 0, &server.security.sa);
    if (h == INVALID_HANDLE_VALUE) {
        return if (first and GetLastError() == ERROR_ACCESS_DENIED) error.AlreadyRunning else error.ListenFailed;
    }
    return h;
}

fn run(server: *Server, first: HANDLE) void {
    const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return;
    var instance: ?HANDLE = first;
    while (true) {
        const h = instance orelse (createInstance(server, false) catch {
            Sleep(1000);
            continue;
        });
        instance = null;
        if (!waitForClient(h, event)) {
            win.CloseHandle(h);
            continue;
        }
        server.lock.lock();
        // A new client replaces the previous one: cancelling its I/O ends
        // that reader thread, which closes the old handle.
        if (server.client) |old| _ = CancelIoEx(old, null);
        server.generation += 1;
        const generation = server.generation;
        server.client = h;
        server.lock.unlock();
        const t = std.Thread.spawn(.{}, serveClient, .{ server, h, generation }) catch {
            closeClient(server, h, generation);
            continue;
        };
        t.detach();
    }
}

fn waitForClient(h: HANDLE, event: HANDLE) bool {
    var ov: OVERLAPPED = .{ .hEvent = event };
    _ = ResetEvent(event);
    if (ok(ConnectNamedPipe(h, &ov))) return true;
    switch (GetLastError()) {
        ERROR_PIPE_CONNECTED => return true,
        ERROR_IO_PENDING => {
            var unused: u32 = 0;
            return ok(GetOverlappedResult(h, &ov, &unused, .TRUE));
        },
        else => return false,
    }
}

fn closeClient(server: *Server, h: HANDLE, generation: u64) void {
    server.write_lock.lock();
    defer server.write_lock.unlock();
    server.lock.lock();
    if (server.generation == generation and server.client != null) {
        server.client = null;
        if (server.hello_generation == generation) server.status.disconnected = true;
    }
    server.lock.unlock();
    _ = DisconnectNamedPipe(h);
    win.CloseHandle(h);
}

fn serveClient(server: *Server, h: HANDLE, generation: u64) void {
    defer closeClient(server, h, generation);
    const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return;
    defer win.CloseHandle(event);
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const buf = server.allocator.alloc(u8, protocol.max_line_bytes + 1) catch return;
    defer server.allocator.free(buf);
    var len: usize = 0;
    var hello = false;
    while (true) {
        var ov: OVERLAPPED = .{ .hEvent = event };
        _ = ResetEvent(event);
        var n: u32 = 0;
        const room: u32 = @intCast(@min(buf.len - len, pipe_buffer_bytes));
        if (!ok(ReadFile(h, buf[len..].ptr, room, null, &ov))) {
            if (GetLastError() != ERROR_IO_PENDING) return;
        }
        if (!ok(GetOverlappedResult(h, &ov, &n, .TRUE))) return;
        if (n == 0) return;
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
                    server.write_lock.lock();
                    const sent = writeAll(server, h, ready);
                    server.write_lock.unlock();
                    if (!sent) return;
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
    var file = std.Io.Dir.openFileAbsolute(io, server.token_path, .{}) catch return false;
    defer file.close(io);
    const n = file.readPositionalAll(io, &token_buf, 0) catch return false;
    if (n == 0 or n == token_buf.len) return false;
    if (!protocol.tokenMatches(token_buf[0..n], hello.token)) return false;
    return hello.protocol == protocol.protocol_version;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "pipeName matches nativeSocketPath (native-protocol.mjs)" {
    // Expected values printed by nativeSocketPath({ platform: 'win32', … }).
    var buf: [pipe_name_len]u8 = undefined;
    try testing.expectEqualStrings(
        "\\\\.\\pipe\\tracinginsights-pet-9df8e1f0ea8f379b",
        pipeName(&buf, "C:\\Users\\Ana\\AppData\\Roaming\\TracingInsights"),
    );
    try testing.expectEqualStrings(
        "\\\\.\\pipe\\tracinginsights-pet-09952dfefab7f901",
        pipeName(&buf, "/home/u/.config/TracingInsights"),
    );
    try testing.expect(pipeNameOk(pipeName(&buf, "x")));
    try testing.expect(!pipeNameOk("\\\\.\\pipe\\tracinginsights-pet-09952DFEFAB7F901"));
    try testing.expect(!pipeNameOk("\\\\.\\pipe\\other-09952dfefab7f901"));
}

test "compiles for Windows" {
    // Analysed everywhere; only a Windows target links the Win32 calls.
    if (builtin.os.tag == .windows) std.testing.refAllDecls(@This());
}
