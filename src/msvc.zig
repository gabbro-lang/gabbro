//! MSVC toolchain discovery.
//!
//! Locates the `VC/Tools/MSVC/<version>/lib/x64` directory that ships
//! `vcruntime.lib`, so linking C libraries against the C runtime works out of the
//! box — without the user passing `-Dmsvc-lib-path` (baked in at gabbro's build time)
//! or `--lib-path`. Windows-only; returns null on other platforms or when no
//! Visual Studio / Build Tools install is found.

const std = @import("std");
const builtin = @import("builtin");

/// Standard 64-bit install roots. Visual Studio 2017+ and the standalone Build
/// Tools both live under `<ProgramFiles*>/Microsoft Visual Studio/<year>/<edition>`.
/// A non-default install drive isn't covered here — use `-Dmsvc-lib-path` for that.
const vs_roots = [_][]const u8{
    "C:/Program Files/Microsoft Visual Studio",
    "C:/Program Files (x86)/Microsoft Visual Studio",
};

/// True if `<dir>/vcruntime.lib` exists.
fn hasVcruntime(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) bool {
    const probe = std.fmt.allocPrint(gpa, "{s}/vcruntime.lib", .{dir}) catch return false;
    defer gpa.free(probe);
    const data = std.Io.Dir.cwd().readFileAlloc(io, probe, gpa, .unlimited) catch return false;
    gpa.free(data);
    return true;
}

/// Best-effort discovery of the MSVC `lib/x64` directory containing
/// `vcruntime.lib`. The caller owns the returned slice (allocated with `gpa`).
/// Returns null if nothing suitable is found.
///
/// Scans the standard install roots and picks the highest MSVC toolset version
/// that actually ships vcruntime.lib. Layout:
///   `<root>/<year>/<edition>/VC/Tools/MSVC/<version>/lib/x64`
pub fn discoverLibX64(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;

    var best: ?[]const u8 = null;
    var best_ver_buf: [64]u8 = undefined;
    var best_ver_len: usize = 0;

    for (vs_roots) |vs_root| {
        var years = std.Io.Dir.cwd().openDir(io, vs_root, .{ .iterate = true }) catch continue;
        defer years.close(io);
        var yit = years.iterate();
        while (yit.next(io) catch null) |ye| {
            if (ye.kind != .directory) continue;
            const year_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ vs_root, ye.name }) catch continue;
            defer gpa.free(year_path);

            var eds = std.Io.Dir.cwd().openDir(io, year_path, .{ .iterate = true }) catch continue;
            defer eds.close(io);
            var eit = eds.iterate();
            while (eit.next(io) catch null) |ee| {
                if (ee.kind != .directory) continue;
                const msvc = std.fmt.allocPrint(gpa, "{s}/{s}/VC/Tools/MSVC", .{ year_path, ee.name }) catch continue;
                defer gpa.free(msvc);

                var vers = std.Io.Dir.cwd().openDir(io, msvc, .{ .iterate = true }) catch continue;
                defer vers.close(io);
                var vit = vers.iterate();
                while (vit.next(io) catch null) |ve| {
                    if (ve.kind != .directory) continue;
                    if (ve.name.len > best_ver_buf.len) continue;
                    // Keep only a strictly newer toolset than the best so far.
                    if (best_ver_len != 0 and
                        std.mem.order(u8, ve.name, best_ver_buf[0..best_ver_len]) != .gt) continue;
                    const cand = std.fmt.allocPrint(gpa, "{s}/{s}/lib/x64", .{ msvc, ve.name }) catch continue;
                    if (hasVcruntime(io, gpa, cand)) {
                        if (best) |b| gpa.free(b);
                        best = cand;
                        @memcpy(best_ver_buf[0..ve.name.len], ve.name);
                        best_ver_len = ve.name.len;
                    } else {
                        gpa.free(cand);
                    }
                }
            }
        }
    }
    return best;
}
