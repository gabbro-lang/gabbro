//! libclang C API binding (`clang-c/Index.h`).
//!
//! The header is `@cImport`ed for its *types/enums/constants* (CXCursor, CXType,
//! the CXType_*/CXCursor_* tags, …), but the **functions are loaded at runtime**
//! via `std.DynLib` rather than linked — so `skarn.exe` carries no dependency on the
//! 81 MB `libclang.dll`. The core compiler never touches it; only `skarn bindgen`
//! calls `load()` (or the lazy `ensureLoaded()`), exactly like Jai's
//! Bindings_Generator module loads libclang on demand. libclang ships as an
//! optional component, not part of the default release.
//!
//! Compiled only in LLVM-enabled builds (`-Dllvm-path=…`), which provide the
//! clang-c headers the `@cImport` needs.
const std = @import("std");
const build_options = @import("build_options");

pub const c = @cImport({
    @cInclude("clang-c/Index.h");
});

/// The libclang functions `bindgen.zig` uses, as runtime-resolved pointers. Each
/// field's type is derived from the `@cImport` declaration (`@TypeOf`), so the
/// signatures can never drift from the header. The field name is the exported
/// symbol — the loader resolves each by `@typeInfo`-iterating these fields.
pub const Lib = struct {
    clang_createIndex: *const @TypeOf(c.clang_createIndex),
    clang_disposeIndex: *const @TypeOf(c.clang_disposeIndex),
    clang_parseTranslationUnit: *const @TypeOf(c.clang_parseTranslationUnit),
    clang_disposeTranslationUnit: *const @TypeOf(c.clang_disposeTranslationUnit),
    clang_getTranslationUnitCursor: *const @TypeOf(c.clang_getTranslationUnitCursor),
    clang_getCursorKind: *const @TypeOf(c.clang_getCursorKind),
    clang_getCursorLocation: *const @TypeOf(c.clang_getCursorLocation),
    clang_getCursorExtent: *const @TypeOf(c.clang_getCursorExtent),
    clang_getCursorType: *const @TypeOf(c.clang_getCursorType),
    clang_getCursorResultType: *const @TypeOf(c.clang_getCursorResultType),
    clang_getCursorSpelling: *const @TypeOf(c.clang_getCursorSpelling),
    clang_isCursorDefinition: *const @TypeOf(c.clang_isCursorDefinition),
    clang_Location_isInSystemHeader: *const @TypeOf(c.clang_Location_isInSystemHeader),
    clang_Cursor_isMacroFunctionLike: *const @TypeOf(c.clang_Cursor_isMacroFunctionLike),
    clang_Cursor_isMacroBuiltin: *const @TypeOf(c.clang_Cursor_isMacroBuiltin),
    clang_Cursor_isBitField: *const @TypeOf(c.clang_Cursor_isBitField),
    clang_Cursor_getNumArguments: *const @TypeOf(c.clang_Cursor_getNumArguments),
    clang_Cursor_getArgument: *const @TypeOf(c.clang_Cursor_getArgument),
    clang_getFileLocation: *const @TypeOf(c.clang_getFileLocation),
    clang_getRangeEnd: *const @TypeOf(c.clang_getRangeEnd),
    clang_tokenize: *const @TypeOf(c.clang_tokenize),
    clang_disposeTokens: *const @TypeOf(c.clang_disposeTokens),
    clang_getTokenKind: *const @TypeOf(c.clang_getTokenKind),
    clang_getTokenLocation: *const @TypeOf(c.clang_getTokenLocation),
    clang_getTokenSpelling: *const @TypeOf(c.clang_getTokenSpelling),
    clang_isFunctionTypeVariadic: *const @TypeOf(c.clang_isFunctionTypeVariadic),
    clang_Type_getSizeOf: *const @TypeOf(c.clang_Type_getSizeOf),
    clang_Type_getAlignOf: *const @TypeOf(c.clang_Type_getAlignOf),
    clang_getEnumConstantDeclValue: *const @TypeOf(c.clang_getEnumConstantDeclValue),
    clang_getTypedefDeclUnderlyingType: *const @TypeOf(c.clang_getTypedefDeclUnderlyingType),
    clang_getCanonicalType: *const @TypeOf(c.clang_getCanonicalType),
    clang_getTypeDeclaration: *const @TypeOf(c.clang_getTypeDeclaration),
    clang_getPointeeType: *const @TypeOf(c.clang_getPointeeType),
    clang_isConstQualifiedType: *const @TypeOf(c.clang_isConstQualifiedType),
    clang_getArraySize: *const @TypeOf(c.clang_getArraySize),
    clang_getArrayElementType: *const @TypeOf(c.clang_getArrayElementType),
    clang_getNumArgTypes: *const @TypeOf(c.clang_getNumArgTypes),
    clang_getArgType: *const @TypeOf(c.clang_getArgType),
    clang_getResultType: *const @TypeOf(c.clang_getResultType),
    clang_getCString: *const @TypeOf(c.clang_getCString),
    clang_disposeString: *const @TypeOf(c.clang_disposeString),
    clang_visitChildren: *const @TypeOf(c.clang_visitChildren),
    clang_getNumDiagnostics: *const @TypeOf(c.clang_getNumDiagnostics),
    clang_getDiagnostic: *const @TypeOf(c.clang_getDiagnostic),
    clang_disposeDiagnostic: *const @TypeOf(c.clang_disposeDiagnostic),
    clang_getDiagnosticSeverity: *const @TypeOf(c.clang_getDiagnosticSeverity),
    clang_formatDiagnostic: *const @TypeOf(c.clang_formatDiagnostic),
    clang_defaultDiagnosticDisplayOptions: *const @TypeOf(c.clang_defaultDiagnosticDisplayOptions),
};

/// The resolved function table. `undefined` until `load`/`ensureLoaded` succeeds;
/// `bindgen.zig` calls through it as `lib.clang_…(…)`.
pub var lib: Lib = undefined;

pub const LoadError = error{ LibclangNotFound, MissingClangSymbol };

const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// This std's `std.DynLib` has no Windows backend (it `@compileError`s there), so
// on Windows we call the loader API directly; on POSIX std.DynLib works.
const win = std.os.windows;
extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?win.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: win.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?win.FARPROC;

const Handle = if (is_windows) win.HMODULE else std.DynLib;
var handle: ?Handle = null;

fn dlOpen(path: []const u8) LoadError!Handle {
    if (is_windows) {
        var wbuf: [std.fs.max_path_bytes]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return error.LibclangNotFound;
        if (n >= wbuf.len) return error.LibclangNotFound;
        wbuf[n] = 0;
        return LoadLibraryW(wbuf[0..n :0].ptr) orelse error.LibclangNotFound;
    } else {
        return std.DynLib.open(path) catch error.LibclangNotFound;
    }
}

fn dlSym(h: *Handle, comptime T: type, name: [:0]const u8) ?T {
    if (is_windows) {
        const p = GetProcAddress(h.*, name.ptr) orelse return null;
        return @ptrCast(@alignCast(p));
    } else {
        return h.lookup(T, name);
    }
}

/// Load libclang from `path` and resolve every `Lib` function. A successful load
/// marks the table ready so `ensureLoaded` becomes a no-op.
pub fn load(path: []const u8) LoadError!void {
    var h = try dlOpen(path);
    inline for (@typeInfo(Lib).@"struct".fields) |f| {
        @field(lib, f.name) = dlSym(&h, f.type, f.name) orelse return error.MissingClangSymbol;
    }
    handle = h; // keep the library mapped for the process lifetime
}

/// Ensure the table is loaded, trying a sensible default location. Used by the
/// in-memory/embedded entry points (and tests) that don't do the CLI's richer
/// path resolution: the build-time LLVM dir (valid on the dev/CI box), then the
/// bare name (the OS loader's search path). The CLI calls `load()` explicitly
/// first with exe-relative / `$SKARN_LIBCLANG` resolution, making this a no-op.
pub fn ensureLoaded() LoadError!void {
    if (handle != null) return;
    const name = libName();
    if (build_options.llvm_path.len != 0) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/bin/{s}", .{ build_options.llvm_path, name })) |p| {
            if (load(p)) |_| return else |_| {}
        } else |_| {}
    }
    return load(name); // bare name → PATH / rpath / loader search
}

/// The platform's libclang shared-object filename.
pub fn libName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "libclang.dll",
        .macos => "libclang.dylib",
        else => "libclang.so",
    };
}
