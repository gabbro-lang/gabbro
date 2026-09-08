const std = @import("std");
const builtin = @import("builtin");
const instructions = @import("instructions.zig");
const value = @import("value.zig");

const Instr = instructions.Instr;
const Opcode = instructions.Opcode;
const BytecodeFunction = instructions.BytecodeFunction;
const BytecodeModule = instructions.BytecodeModule;
const Value = value.Value;
const Sha256 = std.crypto.hash.sha2.Sha256;

// Persistent cache for pure `#run` results. A `#run` that the capability system
// keeps pure is a deterministic function of its bytecode, so we content-address
// it: hash the thunk + its transitive call closure, key a file by that hash, and
// skip the (possibly very slow) VM run when the file already exists.
//
// The whole design leans one way: a missed hit only costs time, a STALE hit is a
// silent wrong build. So `keyFor` refuses to produce a key the moment it sees
// anything whose result it can't fully pin from the bytecode (indirect calls,
// FFI, globals, side effects). No key → the caller just runs, uncached.

/// Bump when the VM's bytecode semantics or this file's encoding change. Old
/// entries then hash differently and are simply never read — never stale.
const format_version: u32 = 1;

pub const Key = [Sha256.digest_length]u8;

/// Default on-disk location, relative to the working directory.
pub const default_dir = ".gabbro-cache/run";

const win = struct {
    const HANDLE = *anyopaque;
    const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const generic_read: u32 = 0x80000000;
    const generic_write: u32 = 0x40000000;
    const share_read: u32 = 0x1;
    const create_always: u32 = 2;
    const open_existing: u32 = 3;
    const attr_normal: u32 = 0x80;
    extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreateDirectoryA(path: [*:0]const u8, sec: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: u32, share: u32, sec: ?*anyopaque, disp: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, to_read: u32, read: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, to_write: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
};

/// The persistent cache is opt-in while it's young: `GABBRO_CACHE=1` (or `on`).
/// Windows-only — the comptime cache is Windows-tested; elsewhere it stays off.
pub fn enabledByEnv() bool {
    if (builtin.target.os.tag != .windows) return false;
    var buf: [8]u8 = undefined;
    const n = win.GetEnvironmentVariableA("GABBRO_CACHE", &buf, buf.len);
    if (n == 0 or n > buf.len) return false;
    const v = buf[0..n];
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on");
}

/// Content key for `entry` (a nullary `#run` thunk) over its transitive
/// direct-call closure in `mod`. Returns null when the closure isn't safely
/// cacheable — the caller then runs without touching the cache. `gpa` is used
/// only for the closure walk's scratch and is fully freed before returning.
pub fn keyFor(gpa: std.mem.Allocator, entry: *const BytecodeFunction, mod: *const BytecodeModule) ?Key {
    var h = Sha256.init(.{});
    feed(&h, u32, format_version);
    // Per-host: comptime float builtins (sin/sqrt/…) can differ across CPUs, so a
    // cache built here must not be read on a different arch.
    h.update(@tagName(builtin.target.os.tag));
    h.update(@tagName(builtin.cpu.arch));

    if (!hashFn(&h, entry)) return null;

    // Breadth-first over direct calls. `visited`/`queue` index into mod.functions.
    const n = mod.functions.len;
    const visited = gpa.alloc(bool, n) catch return null;
    defer gpa.free(visited);
    @memset(visited, false);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);

    if (!enqueueCalls(gpa, entry, &queue, visited)) return null;
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const f = &mod.functions[queue.items[i]];
        if (f.extern_call != null) return null; // FFI in the closure
        if (!hashFn(&h, f)) return null;
        if (!enqueueCalls(gpa, f, &queue, visited)) return null;
    }

    var key: Key = undefined;
    h.final(&key);
    return key;
}

/// Scan `f` for direct calls and enqueue not-yet-seen callee indices. Returns
/// false on an out-of-range index (corrupt bytecode → don't cache).
fn enqueueCalls(gpa: std.mem.Allocator, f: *const BytecodeFunction, queue: *std.ArrayList(u32), visited: []bool) bool {
    for (f.instrs) |ins| {
        if (ins.op != .call) continue;
        if (ins.imm < 0) return false;
        const idx: usize = @intCast(ins.imm);
        if (idx >= visited.len) return false;
        if (visited[idx]) continue;
        visited[idx] = true;
        queue.append(gpa, @intCast(idx)) catch return false;
    }
    return true;
}

/// Hash one function's body. Returns false if it uses anything that makes the
/// result non-deterministic or host-dependent — the conservative bail.
fn hashFn(h: *Sha256, f: *const BytecodeFunction) bool {
    feed(h, u32, f.num_locals);
    feed(h, u32, f.num_params);
    feed(h, u32, @intCast(f.instrs.len));
    for (f.instrs) |ins| {
        switch (ins.op) {
            // Target not statically known, or reaches outside the pure subset.
            .call_indirect,
            .interface_method,
            .load_global,
            .store_global,
            .host_call,
            .host_ptr_make,
            .host_buf_make,
            .sys_print,
            .halt_msg,
            .record_remove,
            => return false,
            else => {},
        }
        feed(h, u8, @intFromEnum(ins.op));
        feed(h, u32, ins.a);
        feed(h, u32, ins.b);
        feed(h, u32, ins.c);
        feed(h, i64, ins.imm);
    }
    feed(h, u32, @intCast(f.constants.len));
    for (f.constants) |c| if (!hashValue(h, c)) return false;
    return true;
}

/// Hash a constant-pool value by its literal content. Anything that isn't a
/// plain literal (a type value, a reference, …) bails — slice 1 only caches
/// closures built from literals.
fn hashValue(h: *Sha256, v: Value) bool {
    switch (v) {
        .int => |x| {
            feed(h, u8, 1);
            feed(h, i128, x);
        },
        .uint => |x| {
            feed(h, u8, 2);
            feed(h, u128, x);
        },
        .float => |x| {
            feed(h, u8, 3);
            feed(h, u64, @bitCast(x));
        },
        .bool => |b| {
            feed(h, u8, 4);
            feed(h, u8, @intFromBool(b));
        },
        .string => |s| {
            feed(h, u8, 5);
            feed(h, u32, @intCast(s.len));
            h.update(s);
        },
        else => return false,
    }
    return true;
}

fn feed(h: *Sha256, comptime T: type, x: T) void {
    var v: T = x;
    h.update(std.mem.asBytes(&v));
}

// Result file: one tag byte + the scalar's bytes. Only scalars are stored; an
// aggregate result encodes to nothing, so it's silently left uncached.
const tag_int: u8 = 1;
const tag_uint: u8 = 2;
const tag_float: u8 = 3;
const tag_bool: u8 = 4;

/// Encode a scalar result into `buf`, returning the byte count, or null if `v`
/// isn't a cacheable scalar.
pub fn encodeResult(buf: *[17]u8, v: Value) ?usize {
    switch (v) {
        .int => |x| {
            buf[0] = tag_int;
            std.mem.writeInt(i128, buf[1..17], x, .little);
            return 17;
        },
        .uint => |x| {
            buf[0] = tag_uint;
            std.mem.writeInt(u128, buf[1..17], x, .little);
            return 17;
        },
        .float => |x| {
            buf[0] = tag_float;
            std.mem.writeInt(u64, buf[1..9], @bitCast(x), .little);
            return 9;
        },
        .bool => |b| {
            buf[0] = tag_bool;
            buf[1] = @intFromBool(b);
            return 2;
        },
        else => return null,
    }
}

/// Decode bytes written by `encodeResult` back into a Value, or null if the
/// bytes don't form a known record (a truncated / future-format file).
pub fn decodeResult(bytes: []const u8) ?Value {
    if (bytes.len == 0) return null;
    switch (bytes[0]) {
        tag_int => {
            if (bytes.len < 17) return null;
            return Value{ .int = std.mem.readInt(i128, bytes[1..][0..16], .little) };
        },
        tag_uint => {
            if (bytes.len < 17) return null;
            return Value{ .uint = std.mem.readInt(u128, bytes[1..][0..16], .little) };
        },
        tag_float => {
            if (bytes.len < 9) return null;
            return Value{ .float = @bitCast(std.mem.readInt(u64, bytes[1..][0..8], .little)) };
        },
        tag_bool => {
            if (bytes.len < 2) return null;
            return Value{ .bool = bytes[1] != 0 };
        },
        else => return null,
    }
}

/// Look up a cached scalar result. Any I/O or decode problem returns null (a
/// miss), never an error — the cache must never break a build.
pub fn loadResult(dir: []const u8, key: Key) ?Value {
    if (builtin.target.os.tag != .windows) return null;
    const name = std.fmt.bytesToHex(key, .lower);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, &name }) catch return null;
    const h = win.CreateFileA(path.ptr, win.generic_read, win.share_read, null, win.open_existing, win.attr_normal, null);
    if (h == win.invalid_handle) return null;
    defer _ = win.CloseHandle(h);
    var buf: [64]u8 = undefined;
    var read: u32 = 0;
    if (win.ReadFile(h, &buf, @intCast(buf.len), &read, null) == 0) return null;
    return decodeResult(buf[0..read]);
}

/// Store a scalar result. Best-effort: a non-scalar or any I/O failure is
/// silently ignored (the value just won't be cached).
pub fn storeResult(dir: []const u8, key: Key, v: Value) void {
    if (builtin.target.os.tag != .windows) return;
    var rec: [17]u8 = undefined;
    const n = encodeResult(&rec, v) orelse return;
    ensureDir(dir);
    const name = std.fmt.bytesToHex(key, .lower);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, &name }) catch return;
    const h = win.CreateFileA(path.ptr, win.generic_write, 0, null, win.create_always, win.attr_normal, null);
    if (h == win.invalid_handle) return;
    defer _ = win.CloseHandle(h);
    var written: u32 = 0;
    _ = win.WriteFile(h, &rec, @intCast(n), &written, null);
}

/// Create `dir` and each parent component (best-effort; already-exists is fine).
fn ensureDir(dir: []const u8) void {
    var i: usize = 0;
    while (i <= dir.len) : (i += 1) {
        if (i != dir.len and dir[i] != '/' and dir[i] != '\\') continue;
        if (i == 0) continue;
        var buf: [512]u8 = undefined;
        const seg = std.fmt.bufPrintZ(&buf, "{s}", .{dir[0..i]}) catch continue;
        _ = win.CreateDirectoryA(seg.ptr, null);
    }
}

const testing = std.testing;

fn oneInstr(op: Opcode, imm: i64) [1]Instr {
    return .{Instr{ .op = op, .imm = imm }};
}

test "identical bodies hash identically; a changed immediate does not" {
    const a_instrs = oneInstr(.load_imm, 7);
    const b_instrs = oneInstr(.load_imm, 7);
    const c_instrs = oneInstr(.load_imm, 8);
    const fa = BytecodeFunction{ .name = "a", .instrs = &a_instrs, .num_regs = 1, .num_locals = 0 };
    const fb = BytecodeFunction{ .name = "b", .instrs = &b_instrs, .num_regs = 1, .num_locals = 0 };
    const fc = BytecodeFunction{ .name = "c", .instrs = &c_instrs, .num_regs = 1, .num_locals = 0 };
    var no_funcs = [_]BytecodeFunction{};
    var empty = BytecodeModule{ .functions = &no_funcs };

    const ka = keyFor(testing.allocator, &fa, &empty).?;
    const kb = keyFor(testing.allocator, &fb, &empty).?;
    const kc = keyFor(testing.allocator, &fc, &empty).?;
    try testing.expectEqualSlices(u8, &ka, &kb); // same body → same key
    try testing.expect(!std.mem.eql(u8, &ka, &kc)); // different literal → different key
}

test "a non-cacheable opcode yields no key" {
    const instrs = oneInstr(.load_global, 0);
    const f = BytecodeFunction{ .name = "g", .instrs = &instrs, .num_regs = 1, .num_locals = 0 };
    var no_funcs = [_]BytecodeFunction{};
    var empty = BytecodeModule{ .functions = &no_funcs };
    try testing.expect(keyFor(testing.allocator, &f, &empty) == null);
}

test "an FFI callee in the closure yields no key" {
    var callee_instrs = [_]Instr{Instr{ .op = .ret_void }};
    var funcs = [_]BytecodeFunction{
        .{ .name = "ffi", .instrs = &callee_instrs, .num_regs = 0, .num_locals = 0, .extern_call = .{ .lib = "kernel32", .symbol = "MulDiv", .returns_value = true } },
    };
    var mod = BytecodeModule{ .functions = &funcs };
    const entry_instrs = oneInstr(.call, 0); // calls function index 0 (the extern)
    const entry = BytecodeFunction{ .name = "entry", .instrs = &entry_instrs, .num_regs = 1, .num_locals = 0 };
    try testing.expect(keyFor(testing.allocator, &entry, &mod) == null);
}

test "scalar results round-trip through encode/decode" {
    const cases = [_]Value{
        .{ .int = -123456789012345 },
        .{ .uint = 18446744073709551615 },
        .{ .float = 3.5 },
        .{ .bool = true },
    };
    for (cases) |v| {
        var buf: [17]u8 = undefined;
        const n = encodeResult(&buf, v).?;
        const back = decodeResult(buf[0..n]).?;
        try testing.expect(std.meta.activeTag(back) == std.meta.activeTag(v));
    }
    // A non-scalar encodes to nothing.
    var scratch: [17]u8 = undefined;
    try testing.expect(encodeResult(&scratch, Value{ .string = "x" }) == null);
}
