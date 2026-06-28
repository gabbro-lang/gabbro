/// Skarn runtime module embedded inside the compiler binary.
///
/// Real programs automatically receive the host runtime, which provides:
///   - write_stdout(data), write_stderr(data)
///   - exit(code), abort()
///   - @panic(msg), assert(cond), assert_msg(cond, msg)
/// On Linux the runtime body is the same; only the ELF entry point differs by
/// ABI: freestanding `_start` (no libc) vs a glibc `_start` that hands off to
/// `__libc_start_main` (the dynamically-linked `linux-gnu` target).
const builtin = @import("builtin");

pub const windows_src = @embedFile("runtime/windows.sk");

const linux_body = @embedFile("runtime/linux.sk");
const linux_start_none = @embedFile("runtime/linux_start_none.sk");
const linux_start_gnu = @embedFile("runtime/linux_start_gnu.sk");

pub const linux_none_src = linux_body ++ "\n" ++ linux_start_none;
pub const linux_gnu_src = linux_body ++ "\n" ++ linux_start_gnu;

/// Backwards-compatible alias (freestanding Linux runtime).
pub const linux_src = linux_none_src;

/// Return the runtime source for a supported platform. `link_libc` selects the
/// glibc entry point on Linux (the `linux-gnu` ABI).
pub fn runtimeSourceFor(os: @TypeOf(builtin.os.tag), link_libc: bool) ?[]const u8 {
    return switch (os) {
        .windows => windows_src,
        .linux => if (link_libc) linux_gnu_src else linux_none_src,
        else => null,
    };
}

/// Return the runtime source for the compiler host (no libc).
pub fn runtimeSource() []const u8 {
    return runtimeSourceFor(builtin.os.tag, false) orelse "";
}
