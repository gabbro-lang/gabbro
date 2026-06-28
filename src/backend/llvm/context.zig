/// ModuleCg — owns the LLVM context, module, and builder for one compilation unit.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const variants = @import("variants.zig");
const abi = @import("abi.zig");

/// Windows x64 stack-probe stub. LLVM emits `call __chkstk` in the prologue of any
/// function whose frame exceeds one page (4 KiB); the CRT that normally supplies
/// `__chkstk` isn't linked in K2's minimal-runtime setup, so we provide it. This is
/// the standard probe-only routine (AT&T): it touches each page of the frame to
/// grow the guard page correctly, preserves RAX/RCX, and lets the caller do the
/// actual `sub rsp, rax`. Emitted weak so future multi-object links don't collide.
const chkstk_x64_asm =
    \\.weak __chkstk
    \\__chkstk:
    \\  push %rcx
    \\  push %rax
    \\  cmp $0x1000, %rax
    \\  lea 24(%rsp), %rcx
    \\  jb 1f
    \\2:
    \\  sub $0x1000, %rcx
    \\  test %rcx, (%rcx)
    \\  sub $0x1000, %rax
    \\  cmp $0x1000, %rax
    \\  ja 2b
    \\1:
    \\  sub %rax, %rcx
    \\  test %rcx, (%rcx)
    \\  pop %rax
    \\  pop %rcx
    \\  ret
    \\
;

/// One entry in a struct's field table.
pub const StructField = struct {
    name: []const u8,
    ir_ty: ir.IrType,
};

pub const ModuleCg = struct {
    allocator: std.mem.Allocator,
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,

    /// Named LLVM struct types keyed by K2 struct name.
    struct_types: std.StringHashMap(llvm.LLVMTypeRef),
    /// Field name/type lists for each named struct.  Used for field-index lookup.
    struct_fields: std.StringHashMap([]StructField),
    struct_alignments: std.StringHashMap(u32),
    /// Declared LLVM functions, keyed by mangled/extern name.
    fn_decls: std.StringHashMap(llvm.LLVMValueRef),
    /// C-ABI lowering for `#extern` functions whose by-value aggregate params or
    /// return need Win64 coercion. Keyed by function name; consulted at call
    /// sites. Only non-trivial signatures are recorded (scalar externs stay on
    /// the fast path). See `abi.zig`.
    fn_abi: std.StringHashMap(abi.FnAbi),
    /// Declared globals, keyed by name.
    global_decls: std.StringHashMap(llvm.LLVMValueRef),
    /// IrType of each global — so field/index access on a `.global` base (e.g.
    /// `STRING_CONST.len`) can find the base's shape. Without it `irTypeOf`
    /// returns null for globals and the access lowers to `undef`.
    global_ir_types: std.StringHashMap(ir.IrType),
    /// Cached { ptr, usize } slice struct type — created once on first use.
    slice_type: ?llvm.LLVMTypeRef = null,
    interface_type: ?llvm.LLVMTypeRef = null,
    closure_type: ?llvm.LLVMTypeRef = null,
    /// Cache of forwarding thunks `__thunk_<fn>` generated for plain functions
    /// used as closure values (so they accept the leading `__env` arg).
    closure_thunks: std.StringHashMap(llvm.LLVMValueRef) = undefined,
    /// Per-enum metadata (discriminants, LLVM type).
    enum_meta: std.StringHashMap(*variants.EnumMeta),
    /// Counter for unique string-literal global names.
    string_counter: u32 = 0,
    /// Cached target data for size/alignment queries during lowering (the
    /// module's real data layout isn't stamped on until just before emit).
    /// The empty-layout default matches x86_64 struct sizes. Lazily created.
    target_data: ?llvm.LLVMTargetDataRef = null,
    /// Error type definitions from the IR module — used for discriminant lookup.
    error_defs: []const ir.ErrorDef = &.{},
    /// Optimisation level (0 = debug). Debug builds insert runtime safety checks.
    opt_level: u2 = 0,
    /// The OS we are generating code for. Defaults to the host; overridden by
    /// `--target` for cross-compilation. Drives the entry point, `__chkstk`, and
    /// `_fltused`.
    target_os: std.Target.Os.Tag = @import("builtin").os.tag,
    /// `--no-entry`: emit no platform entry-point wrapper (`mainCRTStartup`). For
    /// compiling a library object to embed in another binary (e.g. k2lnk into k2).
    no_entry: bool = false,

    /// Set when an internal lowering invariant is violated (e.g. a value's
    /// actual LLVM shape doesn't match what an instruction lowering assumed —
    /// the exact class of bug that previously caused segfaults inside
    /// `LLVMBuildExtractValue`/`InsertValue` on malformed-but-typeable IR).
    ///
    /// Lowering helpers that detect such a mismatch should call
    /// `recordLoweringError` and return a placeholder (e.g. `null`/`undef`)
    /// rather than handing LLVM a value whose shape it doesn't expect — LLVM's
    /// C API does not gracefully reject shape mismatches, it asserts/crashes.
    /// `LlvmBackend.lower` checks this flag once lowering completes and turns
    /// it into a normal `error.LoweringFailed` instead of a process crash.
    lowering_failed: bool = false,

    /// Records an internal codegen-invariant violation.  Prints the message
    /// and the Zig compiler source location so bug reports are actionable.
    /// Safe to call multiple times; only the first call prints.
    pub fn recordLoweringError(
        self: *ModuleCg,
        comptime fmt: []const u8,
        args: anytype,
        comptime src: std.builtin.SourceLocation,
    ) void {
        if (!self.lowering_failed) {
            std.debug.print("k2: internal compiler error: " ++ fmt ++ "\n", args);
            std.debug.print("    [at {s}:{d} in {s}]\n", .{ src.file, src.line, src.fn_name });
        }
        self.lowering_failed = true;
    }

    /// Append the target's required compiler stubs as module-level inline asm.
    /// Windows x64 needs `__chkstk` (large-frame stack probe) since the CRT that
    /// normally supplies it isn't linked. Linux needs nothing here. Call once the
    /// target OS is set, before emission.
    pub fn applyTargetStubs(self: *ModuleCg) void {
        if (self.target_os == .windows and builtin.target.cpu.arch == .x86_64)
            llvm.LLVMAppendModuleInlineAsm(self.mod, chkstk_x64_asm.ptr, chkstk_x64_asm.len);
    }

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) ModuleCg {
        const ctx = llvm.LLVMContextCreate();
        const mod = llvm.LLVMModuleCreateWithNameInContext(module_name, ctx);
        const builder = llvm.LLVMCreateBuilderInContext(ctx);
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .mod = mod,
            .builder = builder,
            .struct_types = std.StringHashMap(llvm.LLVMTypeRef).init(allocator),
            .struct_fields = std.StringHashMap([]StructField).init(allocator),
            .struct_alignments = std.StringHashMap(u32).init(allocator),
            .fn_decls = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .fn_abi = std.StringHashMap(abi.FnAbi).init(allocator),
            .global_decls = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .global_ir_types = std.StringHashMap(ir.IrType).init(allocator),
            .enum_meta = std.StringHashMap(*variants.EnumMeta).init(allocator),
            .closure_thunks = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
        };
    }

    /// Target data for size/alignment queries, created lazily and cached. The
    /// empty layout string yields the default ABI sizes, which match x86_64 for
    /// the struct sizes the C-ABI classifier needs. Mirrors `variants.zig`.
    pub fn targetData(self: *ModuleCg) llvm.LLVMTargetDataRef {
        if (self.target_data) |td| return td;
        const td = llvm.LLVMCreateTargetData("");
        self.target_data = td;
        return td;
    }

    pub fn deinit(self: *ModuleCg) void {
        // Free field lists
        var it = self.struct_fields.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.struct_fields.deinit();

        self.struct_types.deinit();
        self.struct_alignments.deinit();
        self.fn_decls.deinit();
        var abi_it = self.fn_abi.valueIterator();
        while (abi_it.next()) |v| v.deinit(self.allocator);
        self.fn_abi.deinit();
        if (self.target_data) |td| llvm.LLVMDisposeTargetData(td);
        self.global_decls.deinit();
        self.global_ir_types.deinit();
        var em_it = self.enum_meta.valueIterator();
        while (em_it.next()) |v| {
            v.*.discriminants.deinit();
            self.allocator.destroy(v.*);
        }
        self.enum_meta.deinit();
        llvm.LLVMDisposeBuilder(self.builder);
        llvm.LLVMDisposeModule(self.mod);
        llvm.LLVMContextDispose(self.ctx);
    }

    /// Return (and cache) the `{ ptr, usize }` LLVM struct used for all K2 slices.
    pub fn getSliceType(self: *ModuleCg) llvm.LLVMTypeRef {
        if (self.slice_type) |st| return st;
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerTypeInContext(self.ctx, 0), // .ptr
            llvm.LLVMInt64TypeInContext(self.ctx), // .len
        };
        const st = llvm.LLVMStructTypeInContext(self.ctx, &fields, 2, 0);
        self.slice_type = st;
        return st;
    }

    pub fn getInterfaceType(self: *ModuleCg) llvm.LLVMTypeRef {
        if (self.interface_type) |st| return st;
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerTypeInContext(self.ctx, 0),
            llvm.LLVMPointerTypeInContext(self.ctx, 0),
        };
        const st = llvm.LLVMStructTypeInContext(self.ctx, &fields, 2, 0);
        self.interface_type = st;
        return st;
    }

    /// A function value is a fat closure `{ fn: ptr, env: ptr }` — `fn` is the
    /// raw function (or thunk) pointer, `env` the captured environment (null when
    /// there are no captures). Lets every fn-value flow uniformly and lets a
    /// higher-order function accept a closure where a plain fn pointer once went.
    pub fn getClosureType(self: *ModuleCg) llvm.LLVMTypeRef {
        if (self.closure_type) |st| return st;
        var fields = [_]llvm.LLVMTypeRef{
            llvm.LLVMPointerTypeInContext(self.ctx, 0), // .fn
            llvm.LLVMPointerTypeInContext(self.ctx, 0), // .env
        };
        const st = llvm.LLVMStructTypeInContext(self.ctx, &fields, 2, 0);
        self.closure_type = st;
        return st;
    }

    /// Find the zero-based index of a named field in a struct.
    /// Returns null if the struct or field is unknown.
    pub fn fieldIndex(self: *ModuleCg, struct_name: []const u8, field_name: []const u8) ?u32 {
        const fields = self.struct_fields.get(struct_name) orelse return null;
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, field_name)) return @intCast(i);
        }
        return null;
    }

    /// Return the discriminant (1-based) for a named error variant.
    /// Returns 1 as a safe fallback if the type or variant isn't found.
    pub fn errorDiscriminant(self: *const ModuleCg, error_type_name: []const u8, variant_name: []const u8) u32 {
        for (self.error_defs) |def| {
            if (!std.mem.eql(u8, def.name, error_type_name)) continue;
            for (def.variants, 0..) |v, i| {
                if (std.mem.eql(u8, v.name, variant_name)) return @intCast(i + 1);
            }
        }
        return 1; // safe fallback — any non-zero value signals an error
    }
};
