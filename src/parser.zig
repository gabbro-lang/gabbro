const std = @import("std");
const ast = @import("ast.zig");
const diag_mod = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const Span = @import("lexer/span.zig").Span;
const lexer = @import("lexer/tokens.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

pub const ParseResult = struct {
    module: ast.Module,
    next_id: ast.NodeId,
};

pub const ParseError = error{
    ParseFailed,
    OutOfMemory,
};

pub fn parseSource(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
) ParseError!ast.Module {
    const result = try parseSourceFrom(allocator, file_name, source, 1);
    return result.module;
}

pub fn parseSourceFrom(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    next_id: ast.NodeId,
) ParseError!ParseResult {
    var p = try Parser.init(allocator, file_name, source, next_id);
    defer p.deinit();

    const module = p.parseModule() catch |err| {
        // Print diagnostics before p.deinit() frees them.
        for (p.diagnostics.items) |d| {
            const src = if (std.mem.eql(u8, d.file, file_name)) source else "";
            const rendered = diag_mod.renderDiagnostic(allocator, d.file, src, d) catch continue;
            defer allocator.free(rendered);
            std.debug.print("{s}\n", .{rendered});
        }
        return err;
    };
    if (p.diagnostics.items.len != 0) {
        for (p.diagnostics.items) |d| {
            const src = if (std.mem.eql(u8, d.file, file_name)) source else "";
            const rendered = diag_mod.renderDiagnostic(allocator, d.file, src, d) catch continue;
            defer allocator.free(rendered);
            std.debug.print("{s}\n", .{rendered});
        }
        return error.ParseFailed;
    }
    return .{ .module = module, .next_id = p.next_id };
}

pub const BlockResult = struct {
    block: ast.Block,
    next_id: ast.NodeId,
};

/// Parse `source` as a sequence of statements (a brace-less block body). Used
/// by `#parse("...")`: the comptime-produced string is parsed into a block and
/// spliced. Node ids continue from `next_id`.
pub fn parseBlockSource(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    next_id: ast.NodeId,
) ParseError!BlockResult {
    var p = try Parser.init(allocator, file_name, source, next_id);
    defer p.deinit();

    var statements: std.ArrayList(ast.Stmt) = .empty;
    errdefer statements.deinit(allocator);
    while (!p.check(.eof)) {
        try statements.append(allocator, p.parseStmt() catch |err| {
            for (p.diagnostics.items) |d| {
                const rendered = diag_mod.renderDiagnostic(allocator, d.file, source, d) catch continue;
                defer allocator.free(rendered);
                std.debug.print("{s}\n", .{rendered});
            }
            return err;
        });
    }
    if (p.diagnostics.items.len != 0) {
        for (p.diagnostics.items) |d| {
            const rendered = diag_mod.renderDiagnostic(allocator, d.file, source, d) catch continue;
            defer allocator.free(rendered);
            std.debug.print("{s}\n", .{rendered});
        }
        return error.ParseFailed;
    }
    return .{
        .block = .{ .statements = try statements.toOwnedSlice(allocator), .span = Span.new(0, @intCast(source.len)) },
        .next_id = p.next_id,
    };
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    tokens: []Token,
    index: usize = 0,
    next_id: ast.NodeId,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    /// Lambdas (`fn(x){…}` expressions) are lifted to synthetic top-level
    /// functions during parsing: each becomes `__lambda_N` here and the
    /// expression is replaced by an ident referencing it. Appended to the
    /// module's items at the end of `parseModule`.
    lifted_lambdas: std.ArrayList(ast.FunctionDecl) = .empty,
    lambda_counter: u32 = 0,
    /// Functions declared inside a `struct { … }` body are hoisted here as
    /// synthetic top-level functions (named `"<Struct>.<method>"`, with `Self`
    /// resolved to the struct and its type params inherited). Appended to the
    /// module's items at the end of `parseModule`, just like `lifted_lambdas`.
    hoisted_methods: std.ArrayList(ast.FunctionDecl) = .empty,

    pub fn init(allocator: std.mem.Allocator, file_name: []const u8, source: []const u8, next_id: ast.NodeId) !Parser {
        var lex = lexer.Lexer.init(source);
        return .{
            .allocator = allocator,
            .file_name = file_name,
            .source = source,
            .tokens = try lex.all(allocator),
            .next_id = next_id,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
        self.diagnostics.deinit(self.allocator);
        self.lifted_lambdas.deinit(self.allocator);
        self.hoisted_methods.deinit(self.allocator);
    }

    pub fn parseModule(self: *Parser) ParseError!ast.Module {
        var items: std.ArrayList(ast.Item) = .empty;
        errdefer items.deinit(self.allocator);

        while (!self.check(.eof)) {
            // Jai-style `#system_library("name");` — a standalone linking
            // directive, parsed before generic attributes so it isn't
            // mistaken for an attribute attached to the next declaration.
            if (self.check(.hash) and self.checkIdentAt(1, "system_library")) {
                const hash = self.advance();
                _ = self.advance(); // consume "system_library"
                try items.append(self.allocator, .{ .system_library = try self.finishSystemLibrary(hash) });
                continue;
            }

            var attrs = try self.parseAttributes();
            if (self.match(.hash)) {
                try items.append(self.allocator, .{ .import = try self.parseImport(self.previous()) });
                continue;
            }

            const is_public = self.match(.keyword_pub);
            if (is_public) {
                const public_attrs = try self.parseAttributes();
                if (public_attrs.len != 0) {
                    var combined: std.ArrayList(ast.Attribute) = .empty;
                    try combined.appendSlice(self.allocator, attrs);
                    try combined.appendSlice(self.allocator, public_attrs);
                    attrs = try combined.toOwnedSlice(self.allocator);
                }
            }
            try items.append(self.allocator, try self.parseTopLevel(attrs, is_public));
        }

        // Append lambdas lifted from expressions as synthetic top-level functions.
        for (self.lifted_lambdas.items) |decl| {
            try items.append(self.allocator, .{ .function = decl });
        }
        // Append functions hoisted out of struct bodies (in-struct methods).
        for (self.hoisted_methods.items) |decl| {
            try items.append(self.allocator, .{ .function = decl });
        }

        return .{
            .file_name = self.file_name,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn parseImport(self: *Parser, hash: Token) ParseError!ast.ImportDecl {
        _ = try self.expect(.keyword_import, "expected import after #");
        const path = try self.parsePath();
        var names: ?[]const []const u8 = null;
        var glob = false;
        var alias: ?[]const u8 = null;
        if (self.match(.dot_lbrace)) {
            // Selective: `#import a.b.{ x, y };`
            var selected: std.ArrayList([]const u8) = .empty;
            errdefer selected.deinit(self.allocator);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                const name = try self.expect(.ident, "expected imported declaration name");
                try selected.append(self.allocator, name.text(self.source));
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.r_brace, "expected } after selective import");
            names = try selected.toOwnedSlice(self.allocator);
        } else if (self.peekKind(0) == .dot and self.peekKind(1) == .star) {
            // Glob: `#import a.b.*;` — everything unqualified.
            _ = self.advance(); // dot
            _ = self.advance(); // star
            glob = true;
        } else if (self.match(.keyword_as)) {
            // Aliased namespace: `#import a.b as c;`
            alias = (try self.expect(.ident, "expected namespace alias after `as`")).text(self.source);
        }
        const semi = try self.expect(.semicolon, "expected ; after import");
        return .{ .path = path, .names = names, .glob = glob, .alias = alias, .file_name = self.file_name, .span = spanFrom(hash, semi) };
    }

    /// Parses the remainder of `#system_library("name");` after `#` and the
    /// `system_library` identifier have already been consumed.
    fn finishSystemLibrary(self: *Parser, hash: Token) ParseError!ast.SystemLibraryDecl {
        _ = try self.expect(.l_paren, "expected ( after system_library");
        const lit = try self.expect(.string_lit, "expected library name string literal");
        _ = try self.expect(.r_paren, "expected ) after system_library name");
        const semi = try self.expect(.semicolon, "expected ; after system_library declaration");
        return .{
            .name = trimQuotes(lit.text(self.source)),
            .file_name = self.file_name,
            .span = spanFrom(hash, semi),
        };
    }

    fn parseTopLevel(self: *Parser, attrs: []const ast.Attribute, is_public: bool) ParseError!ast.Item {
        const name = try self.expect(.ident, "expected declaration name");
        if (self.match(.keyword_as)) {
            if (attrs.len != 0) {
                try self.errorAt(name, "attributes are not supported on interface implementation blocks");
                return error.ParseFailed;
            }
            if (is_public) {
                try self.errorAt(name, "interface implementation blocks cannot be `pub`");
                return error.ParseFailed;
            }
            return .{ .interface_impl = try self.finishInterfaceImpl(name) };
        }
        // `name: T = init;` — a mutable top-level global. The single `:` (vs `::`)
        // and the `=` (vs the constant's `::`) mark it mutable, exactly like a
        // local variable. `::` is one token, so a bare `:` is unambiguous here.
        if (self.match(.colon)) {
            const ty = try self.parseType();
            _ = try self.expect(.eq, "expected `=` in global variable declaration");
            const value = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after global variable declaration");
            return .{ .const_decl = .{
                .attrs = attrs,
                .name = name.text(self.source),
                .file_name = self.file_name,
                .source = self.source,
                .is_public = is_public,
                .value = value,
                .is_mutable = true,
                .ty = ty,
                .span = spanFrom(name, semi),
            } };
        }
        _ = try self.expect(.colon_colon, "expected :: after declaration name");

        if (self.match(.keyword_fn)) {
            var decl = try self.finishFunction(attrs, name, true);
            decl.is_public = is_public;
            return .{ .function = decl };
        }
        // `name :: macro(...) -> T { ... }` — structurally a function, tagged so
        // the macroexpand pass can collect it and never lower it.
        if (self.matchIdent("macro")) {
            var decl = try self.finishFunction(attrs, name, true);
            decl.is_public = is_public;
            decl.is_macro = true;
            return .{ .function = decl };
        }
        // `Name :: constraint($T) { ... }` — a named comptime type predicate.
        if (self.matchIdent("constraint")) {
            var decl = try self.finishConstraint(attrs, name);
            decl.is_public = is_public;
            return .{ .function = decl };
        }
        if (self.match(.keyword_struct)) {
            var decl = try self.finishStruct(attrs, name);
            decl.is_public = is_public;
            return .{ .type_decl = decl };
        }
        if (self.match(.keyword_interface)) {
            var decl = try self.finishInterface(attrs, name);
            decl.is_public = is_public;
            return .{ .type_decl = decl };
        }
        if (self.match(.keyword_errors)) {
            var decl = try self.finishErrors(attrs, name);
            decl.is_public = is_public;
            return .{ .type_decl = decl };
        }
        if (self.match(.keyword_enum)) {
            var decl = try self.finishEnum(attrs, name);
            decl.is_public = is_public;
            return .{ .type_decl = decl };
        }
        if (self.match(.keyword_distinct)) {
            const ty = try self.parseType();
            const semi = try self.expect(.semicolon, "expected ; after distinct type");
            return .{ .type_decl = .{
                .attrs = attrs,
                .name = name.text(self.source),
                .file_name = self.file_name,
                .is_public = is_public,
                .kind = .{ .distinct = ty },
                .span = spanFrom(name, semi),
            } };
        }
        if (self.match(.keyword_opaque)) {
            const semi = try self.expect(.semicolon, "expected ; after opaque type");
            return .{ .type_decl = .{
                .attrs = attrs,
                .name = name.text(self.source),
                .file_name = self.file_name,
                .is_public = is_public,
                .kind = .opaque_type,
                .span = spanFrom(name, semi),
            } };
        }

        // `Name :: <type>;` — a transparent type alias. Recognised when the RHS
        // begins with an unambiguous type token (a primitive type keyword or a
        // type constructor `[ * [* ? borrow atomic`); a bare-ident RHS stays a
        // value constant.
        if (self.peekStartsType()) {
            const ty = try self.parseType();
            const semi = try self.expect(.semicolon, "expected ; after type alias");
            return .{ .type_decl = .{
                .attrs = attrs,
                .name = name.text(self.source),
                .file_name = self.file_name,
                .is_public = is_public,
                .kind = .{ .alias = ty },
                .span = spanFrom(name, semi),
            } };
        }

        const value = try self.parseExpr(0);
        const semi = try self.expect(.semicolon, "expected ; after constant declaration");
        return .{ .const_decl = .{
            .attrs = attrs,
            .name = name.text(self.source),
            .file_name = self.file_name,
            .source = self.source,
            .is_public = is_public,
            .value = value,
            .span = spanFrom(name, semi),
        } };
    }

    /// Whether the current token begins a type (used to recognise `Name :: <type>`
    /// type aliases vs. value constants). Conservative: a bare ident RHS is NOT a
    /// type here, so `Foo :: Bar` remains a value constant.
    fn peekStartsType(self: *Parser) bool {
        return switch (self.peekKind(0)) {
            .keyword_i8, .keyword_i16, .keyword_i32, .keyword_i64, .keyword_isize, .keyword_u8, .keyword_u16, .keyword_u32, .keyword_u64, .keyword_usize, .keyword_bool, .keyword_void => true,
            .l_bracket, .star, .l_bracket_star, .question, .keyword_borrow, .keyword_atomic => true,
            else => false,
        };
    }

    fn finishInterface(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.TypeDecl {
        const methods = try self.parseMethodBlock(false);
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .file_name = self.file_name,
            .kind = .{ .interface_type = .{ .methods = methods.methods } },
            .span = Span.new(name.start, methods.span.end),
        };
    }

    fn finishInterfaceImpl(self: *Parser, type_name: Token) ParseError!ast.InterfaceImpl {
        const interface_name = try self.expect(.ident, "expected interface name after `as`");
        const methods = try self.parseMethodBlock(true);
        return .{
            .type_name = type_name.text(self.source),
            .interface_name = interface_name.text(self.source),
            .file_name = self.file_name,
            .methods = methods.methods,
            .span = Span.new(type_name.start, methods.span.end),
        };
    }

    const ParsedMethods = struct {
        methods: []const ast.FunctionDecl,
        span: Span,
    };

    fn parseMethodBlock(self: *Parser, require_body: bool) ParseError!ParsedMethods {
        const open = try self.expect(.l_brace, "expected { before methods");
        var methods: std.ArrayList(ast.FunctionDecl) = .empty;
        errdefer methods.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const attrs = try self.parseAttributes();
            const method_name = try self.expect(.ident, "expected method name");
            _ = try self.expect(.colon_colon, "expected :: after method name");
            _ = try self.expect(.keyword_fn, "expected fn after method name");
            const method = try self.finishFunction(attrs, method_name, false);
            if (require_body and method.body == null) {
                try self.errorAt(method_name, "interface implementation method requires a body");
                return error.ParseFailed;
            }
            try methods.append(self.allocator, method);
        }
        const close = try self.expect(.r_brace, "expected } after methods");
        return .{ .methods = try methods.toOwnedSlice(self.allocator), .span = spanFrom(open, close) };
    }

    fn finishStruct(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.TypeDecl {
        // Optional type params: struct($T: type, $U: type) { ... } or, with a
        // constraint, struct($T: Native) { ... } (a built-in or `constraint` name,
        // mirroring fn($T: Name)).
        var type_params: std.ArrayList([]const u8) = .empty;
        errdefer type_params.deinit(self.allocator);
        var type_constraints: std.ArrayList(ast.TypeConstraint) = .empty;
        errdefer type_constraints.deinit(self.allocator);
        if (self.match(.l_paren)) {
            while (!self.check(.r_paren) and !self.check(.eof)) {
                _ = try self.expect(.dollar, "expected $ before struct type param");
                const tp = try self.expect(.ident, "expected type param name");
                _ = try self.expect(.colon, "expected : after type param");
                if (self.match(.keyword_type)) {
                    // Unconstrained: $T: type
                } else if (self.check(.ident)) {
                    // Constrained: $T: ConstraintName
                    const iface_tok = self.advance();
                    try type_constraints.append(self.allocator, .{
                        .param = tp.text(self.source),
                        .interface = iface_tok.text(self.source),
                        .span = spanFrom(tp, iface_tok),
                    });
                } else {
                    _ = try self.expect(.keyword_type, "expected 'type' or a constraint name after $T:");
                }
                try type_params.append(self.allocator, tp.text(self.source));
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.r_paren, "expected ) after struct type params");
        }

        _ = try self.expect(.l_brace, "expected { after struct");
        var fields: std.ArrayList(ast.FieldDecl) = .empty;
        errdefer fields.deinit(self.allocator);
        var methods: std.ArrayList(ast.FunctionDecl) = .empty;
        errdefer methods.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            // An associated declaration: `[pub] name :: fn(...) { ... }`. A field is
            // `name : type`. Disambiguate on `::` vs `:` after the (optional pub +)
            // leading identifier.
            const method_attrs = try self.parseAttributes();
            const is_pub = self.match(.keyword_pub);
            const member_name = try self.expect(.ident, "expected field or method name");
            if (self.match(.colon_colon)) {
                _ = try self.expect(.keyword_fn, "expected fn after `::` in struct body");
                var method = try self.finishFunction(method_attrs, member_name, false);
                method.is_public = is_pub;
                try methods.append(self.allocator, method);
                continue;
            }
            if (method_attrs.len != 0 or is_pub) {
                try self.errorAt(member_name, "struct fields take no attributes or `pub`");
                return error.ParseFailed;
            }
            _ = try self.expect(.colon, "expected : after field name");
            const ty = try self.parseType();
            // Optional default value: `name: T = expr`, used when a literal omits
            // the field.
            const field_default: ?ast.Expr = if (self.match(.eq)) try self.parseExpr(0) else null;
            const end = if (self.match(.comma)) self.previous() else member_name;
            try fields.append(self.allocator, .{
                .name = member_name.text(self.source),
                .ty = ty,
                .default = field_default,
                .span = spanFrom(member_name, end),
            });
        }

        const close = try self.expect(.r_brace, "expected } after struct fields");
        const tps = try type_params.toOwnedSlice(self.allocator);
        const tcs = try type_constraints.toOwnedSlice(self.allocator);
        const fields_slice = try fields.toOwnedSlice(self.allocator);
        const method_decls = try methods.toOwnedSlice(self.allocator);
        // Hoist each in-struct method to a synthetic top-level function so the
        // existing generic/UFCS machinery handles it (see `hoistMethod`). The
        // struct's type-param constraints are inherited by each method so the
        // method call site enforces them via the existing constraint machinery.
        for (method_decls) |m| {
            try self.hoisted_methods.append(self.allocator, try self.hoistMethod(name, tps, tcs, m));
        }
        // `#derive(Eq, …)` — synthesize each requested impl as an in-struct method
        // (built from the struct's fields) and hoist it like any other method.
        for (attrs) |attr| {
            if (!std.mem.eql(u8, attr.name, "derive")) continue;
            for (attr.args) |arg| {
                const which = switch (arg.kind) {
                    .ident => |n| n,
                    else => {
                        try self.errorAt(name, "#derive argument must be a name (e.g. `Eq`)");
                        return error.ParseFailed;
                    },
                };
                // A built-in derive generates its method here; an UNKNOWN name is
                // left in the struct's attributes (no error) for a user `#compiler`
                // hook to handle by reading `Decl.derives` via `compiler_decls()`.
                if (try self.synthDerive(name, tps, which, fields_slice)) |m| {
                    try self.hoisted_methods.append(self.allocator, try self.hoistMethod(name, tps, tcs, m));
                }
            }
        }
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .file_name = self.file_name,
            .kind = .{ .struct_type = .{
                .type_params = tps,
                .type_constraints = tcs,
                .fields = fields_slice,
                .methods = method_decls,
            } },
            .span = spanFrom(name, close),
        };
    }

    /// Generate a derived impl for `#derive(<which>)` as an in-struct method
    /// (`Self`/`*Self` resolved by `hoistMethod`). Returns null for an unknown
    /// derive. THIS IS THE DERIVE REGISTRY — add new generators as cases here.
    /// The generated bodies use the struct's own fields (`==`, `<`, `+`, …), so a
    /// field whose type doesn't support the operation is a clear compile error at
    /// the call site; nested-struct recursion (calling a field's own derived impl)
    /// is a future enhancement.
    fn synthDerive(self: *Parser, struct_name: Token, tps: []const []const u8, which: []const u8, fields: []const ast.FieldDecl) ParseError!?ast.FunctionDecl {
        const sp = spanFrom(struct_name, struct_name);

        // Eq — structural equality: `a.eq(&b)`. A scalar field uses `==`; a nested
        // struct field recurses into its own `.eq` (`self.f.eq(&other.f)`), so Eq
        // composes (the nested type must also derive Eq).
        if (std.mem.eql(u8, which, "Eq")) {
            var chain: ?ast.Expr = null;
            for (fields) |f| {
                const lhs = try self.fld("self", f.name, sp);
                const rhs = try self.fld("other", f.name, sp);
                const cmp = if (fieldIsNamedStruct(f.ty, tps))
                    try self.methodCall(lhs, "eq", &.{try self.addrOf(rhs, sp)}, sp)
                else
                    try self.binop(.equal, lhs, rhs, sp);
                chain = if (chain) |c| try self.binop(.and_and, c, cmp, sp) else cmp;
            }
            const v = chain orelse try self.expr(.{ .bool = true }, sp);
            return try self.synthFn("eq", try self.selfParams(&.{ "self", "other" }, sp), namedType("bool", sp), try self.retOne(v, sp), sp);
        }

        // Ord — 3-way compare: `a.cmp(&b)` → -1 / 0 / 1, lexicographic over fields.
        if (std.mem.eql(u8, which, "Ord")) {
            var stmts: std.ArrayList(ast.Stmt) = .empty;
            for (fields) |f| {
                try stmts.append(self.allocator, try self.ifReturn(.less, f.name, try self.neg(try self.intLit("1", sp), sp), sp));
                try stmts.append(self.allocator, try self.ifReturn(.gt, f.name, try self.intLit("1", sp), sp));
            }
            try stmts.append(self.allocator, .{ .return_stmt = .{ .value = try self.intLit("0", sp), .span = sp } });
            return try self.synthFn("cmp", try self.selfParams(&.{ "self", "other" }, sp), namedType("i32", sp), .{ .statements = try stmts.toOwnedSlice(self.allocator), .span = sp }, sp);
        }

        // Hash — FNV-1a-style mix of the fields cast to u64: `a.hash()`.
        if (std.mem.eql(u8, which, "Hash")) {
            var stmts: std.ArrayList(ast.Stmt) = .empty;
            try stmts.append(self.allocator, .{ .local_typed = .{ .name = "h", .ty = namedType("u64", sp), .value = try self.intLit("14695981039346656037u64", sp), .span = sp } });
            for (fields) |f| {
                const fld_u64 = try self.castTo(try self.fld("self", f.name, sp), "u64", sp);
                const xored = try self.binop(.bit_xor, try self.ident("h", sp), fld_u64, sp);
                const mixed = try self.binop(.wrap_mul, xored, try self.intLit("1099511628211u64", sp), sp);
                try stmts.append(self.allocator, .{ .assign = .{ .target = try self.ident("h", sp), .op = .assign, .value = mixed, .span = sp } });
            }
            try stmts.append(self.allocator, .{ .return_stmt = .{ .value = try self.ident("h", sp), .span = sp } });
            return try self.synthFn("hash", try self.selfParams(&.{"self"}, sp), namedType("u64", sp), .{ .statements = try stmts.toOwnedSlice(self.allocator), .span = sp }, sp);
        }

        // Default — zero/default value: `Type::default()` → `.{}`.
        if (std.mem.eql(u8, which, "Default")) {
            const v = try self.expr(.{ .compound_literal = &.{} }, sp);
            return try self.synthFn("default", &.{}, namedType("Self", sp), try self.retOne(v, sp), sp);
        }

        // Clone — a structural copy: `a.clone()` → `.{ self.f0, self.f1, … }`.
        if (std.mem.eql(u8, which, "Clone")) {
            const elems = try self.allocator.alloc(ast.Expr, fields.len);
            for (fields, 0..) |f, i| elems[i] = try self.fld("self", f.name, sp);
            return try self.synthFn("clone", try self.selfParams(&.{"self"}, sp), namedType("Self", sp), try self.retOne(try self.expr(.{ .compound_literal = elems }, sp), sp), sp);
        }

        // Neg — field-wise negation: `a.neg()` → Self.
        if (std.mem.eql(u8, which, "Neg")) {
            const elems = try self.allocator.alloc(ast.Expr, fields.len);
            for (fields, 0..) |f, i| elems[i] = try self.neg(try self.fld("self", f.name, sp), sp);
            return try self.synthFn("neg", try self.selfParams(&.{"self"}, sp), namedType("Self", sp), try self.retOne(try self.expr(.{ .compound_literal = elems }, sp), sp), sp);
        }

        // Add / Sub / Mul — field-wise arithmetic (`a.add(&b)` …) → Self.
        {
            const op: ?ast.BinaryOp =
                if (std.mem.eql(u8, which, "Add")) .add else if (std.mem.eql(u8, which, "Sub")) .sub else if (std.mem.eql(u8, which, "Mul")) .mul else null;
            if (op) |o| {
                const elems = try self.allocator.alloc(ast.Expr, fields.len);
                for (fields, 0..) |f, i| elems[i] = try self.binop(o, try self.fld("self", f.name, sp), try self.fld("other", f.name, sp), sp);
                const nm = if (o == .add) "add" else if (o == .sub) "sub" else "mul";
                return try self.synthFn(nm, try self.selfParams(&.{ "self", "other" }, sp), namedType("Self", sp), try self.retOne(try self.expr(.{ .compound_literal = elems }, sp), sp), sp);
            }
        }

        // Min / Max — field-wise, via `core::min`/`core::max`: `a.min(&b)` → Self.
        if (std.mem.eql(u8, which, "Min") or std.mem.eql(u8, which, "Max")) {
            const fn_nm = if (std.mem.eql(u8, which, "Min")) "min" else "max";
            const elems = try self.allocator.alloc(ast.Expr, fields.len);
            for (fields, 0..) |f, i| elems[i] = try self.coreCall(fn_nm, &.{ try self.fld("self", f.name, sp), try self.fld("other", f.name, sp) }, sp);
            return try self.synthFn(fn_nm, try self.selfParams(&.{ "self", "other" }, sp), namedType("Self", sp), try self.retOne(try self.expr(.{ .compound_literal = elems }, sp), sp), sp);
        }

        // Clamp — field-wise `core::clamp(self.f, lo.f, hi.f)`: `a.clamp(&lo, &hi)`.
        if (std.mem.eql(u8, which, "Clamp")) {
            const elems = try self.allocator.alloc(ast.Expr, fields.len);
            for (fields, 0..) |f, i| elems[i] = try self.coreCall("clamp", &.{ try self.fld("self", f.name, sp), try self.fld("lo", f.name, sp), try self.fld("hi", f.name, sp) }, sp);
            return try self.synthFn("clamp", try self.selfParams(&.{ "self", "lo", "hi" }, sp), namedType("Self", sp), try self.retOne(try self.expr(.{ .compound_literal = elems }, sp), sp), sp);
        }

        // Scale — multiply every field by a scalar `s` (the first field's type):
        // `a.scale(s)` → Self.
        if (std.mem.eql(u8, which, "Scale") and fields.len > 0) {
            const elems = try self.allocator.alloc(ast.Expr, fields.len);
            for (fields, 0..) |f, i| elems[i] = try self.binop(.mul, try self.fld("self", f.name, sp), try self.ident("s", sp), sp);
            var ps = try self.selfParams(&.{"self"}, sp);
            ps = try self.appendParam(ps, .{ .name = "s", .ty = fields[0].ty, .span = sp });
            return try self.synthFn("scale", ps, namedType("Self", sp), try self.retOne(try self.expr(.{ .compound_literal = elems }, sp), sp), sp);
        }

        // Lerp — field-wise linear interpolation `self.f + (other.f - self.f) * t`:
        // `a.lerp(&b, t)` → Self (t has the first field's type).
        if (std.mem.eql(u8, which, "Lerp") and fields.len > 0) {
            const elems = try self.allocator.alloc(ast.Expr, fields.len);
            for (fields, 0..) |f, i| {
                const delta = try self.binop(.sub, try self.fld("other", f.name, sp), try self.fld("self", f.name, sp), sp);
                const scaled = try self.binop(.mul, delta, try self.ident("t", sp), sp);
                elems[i] = try self.binop(.add, try self.fld("self", f.name, sp), scaled, sp);
            }
            var ps = try self.selfParams(&.{ "self", "other" }, sp);
            ps = try self.appendParam(ps, .{ .name = "t", .ty = fields[0].ty, .span = sp });
            return try self.synthFn("lerp", ps, namedType("Self", sp), try self.retOne(try self.expr(.{ .compound_literal = elems }, sp), sp), sp);
        }

        // format — append a debug rendering to a `std.strings.StringBuilder`:
        // `a.format(sb)` writes `Point { x: 3, y: 4 }`. Requires the struct's file to
        // bring `StringBuilder` into scope (`#import std.strings.{StringBuilder};`).
        if (std.mem.eql(u8, which, "format")) {
            const sname = struct_name.text(self.source);
            var stmts: std.ArrayList(ast.Stmt) = .empty;
            try stmts.append(self.allocator, try self.appendStr(try std.fmt.allocPrint(self.allocator, "{s} {{ ", .{sname}), sp));
            for (fields, 0..) |f, i| {
                const label = if (i == 0)
                    try std.fmt.allocPrint(self.allocator, "{s}: ", .{f.name})
                else
                    try std.fmt.allocPrint(self.allocator, ", {s}: ", .{f.name});
                try stmts.append(self.allocator, try self.appendStr(label, sp));
                try stmts.append(self.allocator, .{ .expr = try self.formatField(f, sp) });
            }
            try stmts.append(self.allocator, try self.appendStr(" }", sp));
            var ps = try self.selfParams(&.{"self"}, sp);
            ps = try self.appendParam(ps, .{ .name = "sb", .ty = .{ .pointer = .{ .inner = try self.allocType(namedType("StringBuilder", sp)), .span = sp } }, .span = sp });
            return try self.synthFn("format", ps, namedType("void", sp), .{ .statements = try stmts.toOwnedSlice(self.allocator), .span = sp }, sp);
        }

        return null;
    }

    /// `sb.append(<text>);` as a statement.
    fn appendStr(self: *Parser, text: []const u8, sp: Span) ParseError!ast.Stmt {
        const lit = try self.expr(.{ .string = text }, sp);
        return .{ .expr = try self.methodCall(try self.ident("sb", sp), "append", &.{lit}, sp) };
    }
    /// Render one field's value into `sb`, dispatched on its type.
    fn formatField(self: *Parser, f: ast.FieldDecl, sp: Span) ParseError!ast.Expr {
        const sb = try self.ident("sb", sp);
        const val = try self.fld("self", f.name, sp);
        switch (f.ty) {
            .named => |n| {
                const name = n.name;
                if (isOneOf(name, &.{ "i8", "i16", "i32", "i64", "isize" }))
                    return self.methodCall(sb, "append_i64", &.{try self.castTo(val, "i64", sp)}, sp);
                if (isOneOf(name, &.{ "u8", "u16", "u32", "u64", "usize", "byte" }))
                    return self.methodCall(sb, "append_u64", &.{try self.castTo(val, "u64", sp)}, sp);
                if (isOneOf(name, &.{ "f32", "f64" }))
                    return self.methodCall(sb, "append_f64", &.{try self.castTo(val, "f64", sp)}, sp);
                if (std.mem.eql(u8, name, "bool"))
                    return self.methodCall(sb, "append_bool", &.{val}, sp);
                // A nested type: recurse into its own `format` (assumes it derives one).
                return self.methodCall(val, "format", &.{sb}, sp);
            },
            .slice => return self.methodCall(sb, "append", &.{val}, sp), // assume []const u8
            else => return self.methodCall(sb, "append", &.{try self.expr(.{ .string = "?" }, sp)}, sp),
        }
    }

    // tiny AST builders for synthesized (derived) code ──────────────────────--
    fn ident(self: *Parser, name: []const u8, sp: Span) ParseError!ast.Expr {
        return self.expr(.{ .ident = name }, sp);
    }
    /// `<base>.<name>` where base is an ident.
    fn fld(self: *Parser, base: []const u8, name: []const u8, sp: Span) ParseError!ast.Expr {
        return self.fieldAccess(try self.ident(base, sp), name, sp);
    }
    fn fieldAccess(self: *Parser, base: ast.Expr, name: []const u8, sp: Span) ParseError!ast.Expr {
        return self.expr(.{ .field = .{ .base = try self.allocExpr(base), .name = name } }, sp);
    }
    fn binop(self: *Parser, op: ast.BinaryOp, l: ast.Expr, r: ast.Expr, sp: Span) ParseError!ast.Expr {
        return self.expr(.{ .binary = .{ .op = op, .left = try self.allocExpr(l), .right = try self.allocExpr(r) } }, sp);
    }
    fn intLit(self: *Parser, text: []const u8, sp: Span) ParseError!ast.Expr {
        return self.expr(.{ .int = text }, sp);
    }
    fn neg(self: *Parser, e: ast.Expr, sp: Span) ParseError!ast.Expr {
        return self.expr(.{ .unary = .{ .op = .neg, .expr = try self.allocExpr(e) } }, sp);
    }
    fn addrOf(self: *Parser, e: ast.Expr, sp: Span) ParseError!ast.Expr {
        return self.expr(.{ .unary = .{ .op = .address_of, .expr = try self.allocExpr(e) } }, sp);
    }
    fn castTo(self: *Parser, e: ast.Expr, ty_name: []const u8, sp: Span) ParseError!ast.Expr {
        return self.expr(.{ .as_cast = .{ .value = try self.allocExpr(e), .to = namedType(ty_name, sp) } }, sp);
    }
    /// `if self.<f> <op> other.<f> { return <ret>; }`
    fn ifReturn(self: *Parser, op: ast.BinaryOp, f: []const u8, ret: ast.Expr, sp: Span) ParseError!ast.Stmt {
        const cond = try self.binop(op, try self.fld("self", f, sp), try self.fld("other", f, sp), sp);
        return .{ .if_stmt = .{ .binding = null, .payload_binding = null, .condition = cond, .then_block = try self.oneStmt(.{ .return_stmt = .{ .value = ret, .span = sp } }, sp), .else_block = null, .span = sp } };
    }
    fn oneStmt(self: *Parser, s: ast.Stmt, sp: Span) ParseError!ast.Block {
        const stmts = try self.allocator.alloc(ast.Stmt, 1);
        stmts[0] = s;
        return .{ .statements = stmts, .span = sp };
    }
    /// A one-statement body that just `return`s `v`.
    fn retOne(self: *Parser, v: ast.Expr, sp: Span) ParseError!ast.Block {
        return self.oneStmt(.{ .return_stmt = .{ .value = v, .span = sp } }, sp);
    }
    /// A slice of `*Self` value params with the given names.
    fn selfParams(self: *Parser, names: []const []const u8, sp: Span) ParseError![]ast.Param {
        const ps = try self.allocator.alloc(ast.Param, names.len);
        for (names, 0..) |n, i| ps[i] = .{ .name = n, .ty = .{ .pointer = .{ .inner = try self.allocType(namedType("Self", sp)), .span = sp } }, .span = sp };
        return ps;
    }
    /// Append one more parameter to a params slice (for a scalar `s`/`t` or `sb`).
    fn appendParam(self: *Parser, ps: []ast.Param, p: ast.Param) ParseError![]ast.Param {
        const out = try self.allocator.alloc(ast.Param, ps.len + 1);
        @memcpy(out[0..ps.len], ps);
        out[ps.len] = p;
        return out;
    }
    /// `recv.method(args…)` — a UFCS method call.
    fn methodCall(self: *Parser, recv: ast.Expr, method: []const u8, args: []const ast.Expr, sp: Span) ParseError!ast.Expr {
        const callee = try self.fieldAccess(recv, method, sp);
        const cargs = try self.allocator.alloc(ast.CallArg, args.len);
        for (args, 0..) |a, i| cargs[i] = .{ .positional = a };
        return self.expr(.{ .call = .{ .callee = try self.allocExpr(callee), .args = cargs } }, sp);
    }
    /// `core::<member>(args…)`.
    fn coreCall(self: *Parser, member: []const u8, args: []const ast.Expr, sp: Span) ParseError!ast.Expr {
        const callee = try self.expr(.{ .scope_access = .{ .base = try self.allocExpr(try self.ident("core", sp)), .member = member } }, sp);
        const cargs = try self.allocator.alloc(ast.CallArg, args.len);
        for (args, 0..) |a, i| cargs[i] = .{ .positional = a };
        return self.expr(.{ .call = .{ .callee = try self.allocExpr(callee), .args = cargs } }, sp);
    }
    /// Build a public synthesized fn with the given parameters.
    fn synthFn(self: *Parser, name: []const u8, params: []const ast.Param, ret: ast.TypeRef, body: ast.Block, sp: Span) ParseError!ast.FunctionDecl {
        return ast.FunctionDecl{
            .attrs = &.{},
            .name = name,
            .file_name = self.file_name,
            .source = self.source,
            .is_public = true,
            .type_params = &.{},
            .params = params,
            .return_ty = ret,
            .error_ty = null,
            .body = body,
            .span = sp,
        };
    }

    /// Turn an in-struct method into a top-level function named `"<Struct>.<m>"`:
    /// inherit the struct's type params (as inferred type vars — names only, never
    /// passed explicitly) and substitute `Self` with the struct type so the body
    /// and signature resolve in the ordinary top-level context.
    fn hoistMethod(self: *Parser, struct_name: Token, struct_tps: []const []const u8, struct_tcs: []const ast.TypeConstraint, m: ast.FunctionDecl) ParseError!ast.FunctionDecl {
        const sname = struct_name.text(self.source);
        // The Self target: `Struct` (no type params) or `Struct(T, …)` (generic).
        const self_ref: ast.TypeRef = if (struct_tps.len == 0)
            .{ .named = .{ .name = sname, .span = spanFrom(struct_name, struct_name) } }
        else blk: {
            const args = try self.allocator.alloc(ast.TypeRef, struct_tps.len);
            for (struct_tps, 0..) |tp, i| {
                args[i] = .{ .type_param = .{ .name = tp, .span = spanFrom(struct_name, struct_name) } };
            }
            break :blk .{ .generic_inst = .{ .name = sname, .args = args, .span = spanFrom(struct_name, struct_name) } };
        };

        // Substitute Self in every parameter type and the return type.
        const params = try self.allocator.alloc(ast.Param, m.params.len);
        for (m.params, 0..) |p, i| {
            params[i] = .{
                .name = p.name,
                .ty = try self.substSelf(p.ty, self_ref),
                .is_type_param = p.is_type_param,
                .span = p.span,
            };
        }
        const return_ty = try self.substSelf(m.return_ty, self_ref);

        // type_params = struct's (inferred) ++ method's own. Struct type params are
        // names only here (no `$T` param), so they are inferred from the args, never
        // passed explicitly.
        var tps: std.ArrayList([]const u8) = .empty;
        try tps.appendSlice(self.allocator, struct_tps);
        try tps.appendSlice(self.allocator, m.type_params);

        // type_constraints = struct's (inherited, on the struct's $T) ++ method's own.
        // The struct constraints reference struct type params, which are included in
        // `tps`, so the existing call-site machinery checks them on each method call.
        var tcs: std.ArrayList(ast.TypeConstraint) = .empty;
        try tcs.appendSlice(self.allocator, struct_tcs);
        try tcs.appendSlice(self.allocator, m.type_constraints);

        const mangled = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ sname, m.name });
        return .{
            .attrs = m.attrs,
            .name = mangled,
            .file_name = self.file_name,
            .source = self.source,
            .is_public = m.is_public,
            .type_params = try tps.toOwnedSlice(self.allocator),
            .output_type_params = m.output_type_params,
            .type_constraints = try tcs.toOwnedSlice(self.allocator),
            .params = params,
            .return_ty = return_ty,
            .error_ty = m.error_ty,
            .where_clause = m.where_clause,
            .body = m.body,
            .span = m.span,
        };
    }

    /// Recursively replace `Self` (a bare named type) with `target` inside a TypeRef.
    fn substSelf(self: *Parser, ty: ast.TypeRef, target: ast.TypeRef) ParseError!ast.TypeRef {
        switch (ty) {
            .named => |n| {
                if (n.namespace == null and std.mem.eql(u8, n.name, "Self")) return target;
                return ty;
            },
            .pointer => |p| {
                const inner = try self.allocator.create(ast.TypeRef);
                inner.* = try self.substSelf(p.inner.*, target);
                return .{ .pointer = .{ .is_const = p.is_const, .is_volatile = p.is_volatile, .inner = inner, .span = p.span } };
            },
            .many_pointer => |p| {
                const inner = try self.allocator.create(ast.TypeRef);
                inner.* = try self.substSelf(p.inner.*, target);
                return .{ .many_pointer = .{ .is_const = p.is_const, .is_volatile = p.is_volatile, .inner = inner, .span = p.span } };
            },
            .optional => |o| {
                const inner = try self.allocator.create(ast.TypeRef);
                inner.* = try self.substSelf(o.inner.*, target);
                return .{ .optional = .{ .inner = inner, .span = o.span } };
            },
            .slice => |s| {
                const inner = try self.allocator.create(ast.TypeRef);
                inner.* = try self.substSelf(s.inner.*, target);
                return .{ .slice = .{ .is_const = s.is_const, .inner = inner, .span = s.span } };
            },
            else => return ty,
        }
    }

    fn parseComptimeDirective(self: *Parser, hash: Token) ParseError!ast.Stmt {
        // #if cond { ... } else { ... }
        if (self.match(.keyword_if)) {
            const start = self.previous();
            const cond = try self.parseExpr(0);
            const then_block = try self.parseBlock();
            const else_block = if (self.match(.keyword_else)) try self.parseBlock() else null;
            const end = if (else_block) |b| b.span else then_block.span;
            return .{ .comptime_if = .{
                .condition = cond,
                .then_block = then_block,
                .else_block = else_block,
                .span = spanFrom(start, end),
            } };
        }
        // #run { ... }  or  #run expr;
        if (self.matchIdent("run")) {
            if (self.check(.l_brace)) {
                return .{ .comptime_run = try self.parseBlock() };
            }
            // Single-statement #run expr;
            const stmt = try self.parseStmt();
            var stmts: std.ArrayList(ast.Stmt) = .empty;
            errdefer stmts.deinit(self.allocator);
            try stmts.append(self.allocator, stmt);
            const body = ast.Block{
                .statements = try stmts.toOwnedSlice(self.allocator),
                .span = Span.new(hash.start, hash.start + hash.len),
            };
            return .{ .comptime_run = body };
        }
        // #insert <expr>;  — splice compile-time-generated code here.
        if (self.matchIdent("insert")) {
            const operand = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after #insert operand");
            return .{ .insert_stmt = .{
                .operand = operand,
                .span = spanFrom(hash, semi),
            } };
        }
        // #for i in a..b { ... } — a compile-time unrolled loop.
        if (self.match(.keyword_for)) {
            const binding = try self.expect(.ident, "expected loop binding after #for");
            _ = try self.expect(.keyword_in, "expected `in` after #for binding");
            const start_expr = try self.parseExpr(0);
            if (!(self.match(.dot_dot) or self.match(.dot_dot_eq))) {
                try self.errorAt(self.peek(), "#for requires a range `a..b` or `a..=b`");
                return error.ParseFailed;
            }
            const inclusive = self.previous().kind == .dot_dot_eq;
            const end_expr = try self.parseExpr(0);
            const body = try self.parseBlock();
            return .{ .comptime_for = .{
                .binding = binding.text(self.source),
                .start = start_expr,
                .end = end_expr,
                .inclusive = inclusive,
                .body = body,
                .span = Span.new(hash.start, body.span.end),
            } };
        }
        try self.errorAt(hash, "unknown compile-time directive; expected #if, #run, #insert, or #for");
        return error.ParseFailed;
    }

    fn finishEnum(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.TypeDecl {
        _ = try self.expect(.l_brace, "expected { after enum");
        var variants: std.ArrayList(ast.EnumVariantDecl) = .empty;
        errdefer variants.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const start = self.peek();
            _ = self.match(.dot); // optional leading dot
            const variant_name = try self.expect(.ident, "expected variant name");
            const payload = if (self.match(.colon)) try self.parseType() else null;
            const end = if (self.match(.comma)) self.previous() else variant_name;
            try variants.append(self.allocator, .{
                .name = variant_name.text(self.source),
                .payload = payload,
                .span = spanFrom(start, end),
            });
        }

        const close = try self.expect(.r_brace, "expected } after enum variants");
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .file_name = self.file_name,
            .kind = .{ .enum_type = .{ .variants = try variants.toOwnedSlice(self.allocator) } },
            .span = spanFrom(name, close),
        };
    }

    fn parseMatch(self: *Parser, start: Token) ParseError!ast.MatchStmt {
        const subject = try self.parseExpr(0);
        _ = try self.expect(.l_brace, "expected { after match subject");

        var arms: std.ArrayList(ast.MatchArm) = .empty;
        errdefer arms.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const arm_start = self.peek();
            const pattern = try self.parseMatchPattern();
            const binding = try self.parseMatchBinding();
            const guard = try self.parseMatchGuard();

            _ = try self.expect(.fat_arrow, "expected => after match pattern");

            // Body: either a block { ... } or a single statement.
            const body = if (self.check(.l_brace)) blk: {
                const b = try self.parseBlock();
                _ = self.match(.comma);
                break :blk b;
            } else blk: {
                const arm_start_tok = self.peek();
                const arm_stmt = try self.parseStmt();
                _ = self.match(.comma);
                var stmts: std.ArrayList(ast.Stmt) = .empty;
                errdefer stmts.deinit(self.allocator);
                try stmts.append(self.allocator, arm_stmt);
                break :blk ast.Block{
                    .statements = try stmts.toOwnedSlice(self.allocator),
                    .span = spanFrom(arm_start_tok, self.previous()),
                };
            };

            try arms.append(self.allocator, .{
                .pattern = pattern,
                .binding = binding,
                .guard = guard,
                .body = body,
                .span = spanFrom(arm_start, body.span),
            });
        }

        const close = try self.expect(.r_brace, "expected } after match arms");
        return .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(self.allocator),
            .span = spanFrom(start, close),
        };
    }

    /// Parse one match pattern. Shared by statement- and expression-matches:
    ///   `else` · integers (`1`, grouped `1, 2, 3`) · ranges (`1..5`, `1..=5`) ·
    ///   strings (`"a"`, grouped `"a", "b"`) · enum variants (`.name`) ·
    ///   a bare identifier (a named catch-all binding).
    fn parseMatchPattern(self: *Parser) ParseError!ast.MatchPattern {
        if (self.match(.keyword_else)) return .else_arm;

        if (self.check(.string_lit)) {
            var values: std.ArrayList([]const u8) = .empty;
            errdefer values.deinit(self.allocator);
            try values.append(self.allocator, self.advance().text(self.source));
            while (self.check(.comma) and self.peekKind(1) == .string_lit) {
                _ = self.advance(); // comma
                try values.append(self.allocator, self.advance().text(self.source));
            }
            return .{ .strings = try values.toOwnedSlice(self.allocator) };
        }

        if (self.check(.int_lit)) {
            const first = try self.parseExpr(0);
            if (self.match(.dot_dot) or self.match(.dot_dot_eq)) {
                const inclusive = self.previous().kind == .dot_dot_eq;
                const hi = try self.parseExpr(0);
                return .{ .range = .{ .lo = first, .hi = hi, .inclusive = inclusive } };
            }
            var values: std.ArrayList(ast.Expr) = .empty;
            errdefer values.deinit(self.allocator);
            try values.append(self.allocator, first);
            while (self.check(.comma) and self.peekKind(1) == .int_lit) {
                _ = self.advance();
                try values.append(self.allocator, try self.parseExpr(0));
            }
            return .{ .int_values = try values.toOwnedSlice(self.allocator) };
        }

        if (self.match(.dot)) {
            const vname = try self.expect(.ident, "expected variant name");
            return .{ .enum_variant = vname.text(self.source) };
        }

        const id = try self.expect(.ident, "expected a match pattern (`.variant`, integer, string, a name, or `else`)");
        return .{ .binding = id.text(self.source) };
    }

    /// Optional payload binding after a pattern: `|x|`.
    fn parseMatchBinding(self: *Parser) ParseError!?[]const u8 {
        if (self.match(.pipe)) {
            const bname = try self.expect(.ident, "expected binding name");
            _ = try self.expect(.pipe, "expected closing | after binding");
            return bname.text(self.source);
        }
        return null;
    }

    /// Optional guard after a pattern/binding: `if <cond>`.
    fn parseMatchGuard(self: *Parser) ParseError!?ast.Expr {
        if (self.match(.keyword_if)) return try self.parseExpr(0);
        return null;
    }

    /// `match subject { pattern => value, ... }` in value position. Each arm's
    /// body is an expression (the arm's value); arms are comma-separated.
    fn parseMatchExpr(self: *Parser, start: Token) ParseError!ast.Expr {
        const subject = try self.allocExpr(try self.parseExpr(0));
        _ = try self.expect(.l_brace, "expected { after match subject");

        var arms: std.ArrayList(ast.MatchExprArm) = .empty;
        errdefer arms.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const arm_start = self.peek();
            const pattern = try self.parseMatchPattern();
            const binding = try self.parseMatchBinding();
            const guard = try self.parseMatchGuard();
            _ = try self.expect(.fat_arrow, "expected => after match pattern");
            const value = try self.parseExpr(0);
            _ = self.match(.comma);
            try arms.append(self.allocator, .{
                .pattern = pattern,
                .binding = binding,
                .guard = guard,
                .value = value,
                .span = spanFrom(arm_start, self.previous()),
            });
        }

        const close = try self.expect(.r_brace, "expected } after match arms");
        const me = try self.allocator.create(ast.MatchExpr);
        me.* = .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(self.allocator),
            .span = spanFrom(start, close),
        };
        return self.expr(.{ .match_expr = me }, spanFrom(start, close));
    }

    /// `if cond { value } else { value }` / `if c { a } else if d { b } else { c }`
    /// — a value-producing if. Each branch is a single expression in braces; an
    /// `else` is mandatory (an expression must always produce a value).
    fn parseIfExpr(self: *Parser, start: Token) ParseError!ast.Expr {
        const cond = try self.parseExpr(0);
        _ = try self.expect(.l_brace, "expected { after if-expression condition");
        const then_value = try self.parseExpr(0);
        const close_then = try self.expect(.r_brace, "expected } after if-expression branch");
        _ = try self.expect(.keyword_else, "an if-expression must have an `else` branch");

        const else_value: ast.Expr = if (self.match(.keyword_if))
            try self.parseIfExpr(self.previous()) // `else if …` chain
        else blk: {
            _ = try self.expect(.l_brace, "expected { after else");
            const v = try self.parseExpr(0);
            _ = try self.expect(.r_brace, "expected } after else branch");
            break :blk v;
        };

        const ie = try self.allocator.create(ast.IfExpr);
        ie.* = .{
            .cond = cond,
            .then_value = then_value,
            .else_value = else_value,
            .span = spanFrom(start, self.previous()),
        };
        _ = close_then;
        return self.expr(.{ .if_expr = ie }, spanFrom(start, self.previous()));
    }

    fn finishErrors(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.TypeDecl {
        _ = try self.expect(.l_brace, "expected { after errors");
        const variants = try self.parseErrorVariants(.r_brace);
        const close = try self.expect(.r_brace, "expected } after errors");
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .file_name = self.file_name,
            .kind = .{ .errors = .{ .variants = variants } },
            .span = spanFrom(name, close),
        };
    }

    fn parseErrorVariants(self: *Parser, end_kind: TokenKind) ParseError![]const ast.ErrorVariantDecl {
        var variants: std.ArrayList(ast.ErrorVariantDecl) = .empty;
        errdefer variants.deinit(self.allocator);

        while (!self.check(end_kind) and !self.check(.eof)) {
            const start = self.peek();
            _ = self.match(.dot);
            const variant_name = try self.expect(.ident, "expected error variant name");
            const payload = if (self.match(.colon)) try self.parseType() else null;
            const end = if (self.match(.comma)) self.previous() else variant_name;
            try variants.append(self.allocator, .{
                .name = variant_name.text(self.source),
                .payload = payload,
                .span = spanFrom(start, end),
            });
        }

        return variants.toOwnedSlice(self.allocator);
    }

    fn parseErrorSpec(self: *Parser, bang: Token) ParseError!ast.ErrorSpec {
        if (self.check(.l_brace) and self.peekKind(1) == .dot) {
            _ = self.advance();
            const variants = try self.parseErrorVariants(.r_brace);
            const close = try self.expect(.r_brace, "expected } after inline error set");
            return .{ .inline_set = .{ .variants = variants, .span = spanFrom(bang, close) } };
        }
        if (isTypeName(self.peek().kind)) {
            const first = self.advance();
            // `! ns::Error` — a qualified error type from an imported module.
            if (self.match(.colon_colon)) {
                const member = try self.expect(.ident, "expected error type name after `::`");
                return .{ .named = .{
                    .namespace = first.text(self.source),
                    .name = member.text(self.source),
                    .span = spanFrom(first, member),
                } };
            }
            return .{ .named = .{ .name = first.text(self.source), .span = spanFrom(first, first) } };
        }
        return .{ .inferred = spanFrom(bang, bang) };
    }

    /// `Name :: constraint($T) { body }` — a named comptime type predicate. Built
    /// as a generic predicate function (one type param, no value params, the body
    /// is the predicate); `is_constraint` marks it so it's never lowered.
    fn finishConstraint(self: *Parser, attrs: []const ast.Attribute, name: Token) ParseError!ast.FunctionDecl {
        _ = try self.expect(.l_paren, "expected ( after constraint");
        _ = try self.expect(.dollar, "expected $ before constraint type param");
        const tp = try self.expect(.ident, "expected type parameter name after $");
        _ = try self.expect(.r_paren, "expected ) after constraint type param");
        const body = try self.parseBlock();
        var type_params: std.ArrayList([]const u8) = .empty;
        errdefer type_params.deinit(self.allocator);
        try type_params.append(self.allocator, tp.text(self.source));
        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .file_name = self.file_name,
            .source = self.source,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .params = &.{},
            .return_ty = namedType("void", spanFrom(name, name)),
            .error_ty = null,
            .body = body,
            .is_constraint = true,
            .span = Span.new(name.start, body.span.end),
        };
    }

    /// At a `fn` in expression position (the `fn` token consumed, `self.index`
    /// on the `(`), decide whether it's a lambda `fn(…){…}` or a fn-pointer
    /// *type* `fn(…)->R` (used as a builtin type-arg). The distinguisher is a
    /// trailing `{ body }`: scan to the matching `)`, skip an optional `-> <type>`,
    /// and a `{` next means a lambda.
    fn lambdaAhead(self: Parser) bool {
        if (self.peekKind(0) != .l_paren) return false;
        // Fast path: a named first parameter (`fn(x: …`) is unambiguously a lambda.
        if (self.peekKind(1) == .ident and self.peekKind(2) == .colon) return true;
        // Scan to the matching `)`.
        var off: usize = 0;
        var depth: i32 = 0;
        while (true) : (off += 1) {
            switch (self.peekKind(off)) {
                .l_paren => depth += 1,
                .r_paren => {
                    depth -= 1;
                    if (depth == 0) {
                        off += 1;
                        break;
                    }
                },
                .eof => return false,
                else => {},
            }
        }
        // Skip an optional `-> <return type>`; a `{` ends the signature → lambda.
        if (self.peekKind(off) == .arrow) {
            off += 1;
            var d2: i32 = 0;
            while (true) : (off += 1) {
                switch (self.peekKind(off)) {
                    .l_paren, .l_bracket => d2 += 1,
                    .r_paren, .r_bracket => {
                        d2 -= 1;
                        if (d2 < 0) return false; // hit an enclosing close → a type
                    },
                    .l_brace => if (d2 == 0) return true,
                    .semicolon, .comma, .eof, .r_brace => return false,
                    else => {},
                }
            }
        }
        return self.peekKind(off) == .l_brace;
    }

    /// Parse a lambda `fn(name: T, …) [-> R] { body }` (the `fn` token is already
    /// consumed). The lambda is lifted to a synthetic top-level function and the
    /// expression becomes an ident referencing it. No captures yet: the body sees
    /// only its parameters and globals.
    fn parseLambda(self: *Parser, fn_tok: Token) ParseError!ast.Expr {
        _ = try self.expect(.l_paren, "expected ( after fn");
        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        if (!self.check(.r_paren)) {
            while (true) {
                const pname = try self.expect(.ident, "expected parameter name");
                _ = try self.expect(.colon, "expected : after parameter name");
                const ty = try self.parseType();
                try params.append(self.allocator, .{ .name = pname.text(self.source), .ty = ty, .span = ty.span() });
                if (!self.match(.comma)) break;
                if (self.check(.r_paren)) break;
            }
        }
        _ = try self.expect(.r_paren, "expected ) after lambda parameters");
        const return_ty = if (self.match(.arrow)) try self.parseType() else namedType("void", spanFrom(fn_tok, fn_tok));
        const body = try self.parseBlock();
        const name = try std.fmt.allocPrint(self.allocator, "__lambda_{d}", .{self.lambda_counter});
        self.lambda_counter += 1;
        try self.lifted_lambdas.append(self.allocator, .{
            .attrs = &.{},
            .name = name,
            .file_name = self.file_name,
            .source = self.source,
            .type_params = &.{},
            .params = try params.toOwnedSlice(self.allocator),
            .return_ty = return_ty,
            .error_ty = null,
            .body = body,
            .span = Span.new(fn_tok.start, body.span.end),
        });
        return self.expr(.{ .ident = name }, Span.new(fn_tok.start, body.span.end));
    }

    fn finishFunction(self: *Parser, attrs: []const ast.Attribute, name: Token, top_level: bool) ParseError!ast.FunctionDecl {
        _ = top_level;
        _ = try self.expect(.l_paren, "expected ( after fn");
        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        var type_params: std.ArrayList([]const u8) = .empty;
        errdefer type_params.deinit(self.allocator);
        var type_constraints: std.ArrayList(ast.TypeConstraint) = .empty;
        errdefer type_constraints.deinit(self.allocator);

        if (!self.check(.r_paren)) {
            while (true) {
                if (self.match(.dollar)) {
                    // $T                  — bare type param (a `where T: …` clause may constrain it)
                    // $T: type            — unconstrained type param
                    // $T: InterfaceName   — constrained type param
                    const tp_name = try self.expect(.ident, "expected type parameter name after $");
                    if (self.match(.colon)) {
                        if (self.match(.keyword_type)) {
                            // Unconstrained: $T: type
                        } else if (self.check(.ident)) {
                            // Constrained: $T: InterfaceName
                            const iface_tok = self.advance();
                            try type_constraints.append(self.allocator, .{
                                .param = tp_name.text(self.source),
                                .interface = iface_tok.text(self.source),
                                .span = spanFrom(tp_name, iface_tok),
                            });
                        } else {
                            return error.ParseFailed;
                        }
                    }
                    try type_params.append(self.allocator, tp_name.text(self.source));
                    try params.append(self.allocator, .{
                        .name = tp_name.text(self.source),
                        .ty = .{ .type_param = .{ .name = tp_name.text(self.source), .span = spanFrom(tp_name, tp_name) } },
                        .is_type_param = true,
                        .span = spanFrom(tp_name, tp_name),
                    });
                } else {
                    // Regular param, but type may be $T (introducing a type variable).
                    // Syntax: name: $T   or   name: T  (T already introduced)
                    const param_name = try self.expect(.ident, "expected parameter name");
                    _ = try self.expect(.colon, "expected : after parameter name");
                    if (self.match(.dollar)) {
                        // a: $T — introduces type variable T, param type is T
                        const tp_name = try self.expect(.ident, "expected type variable name after $");
                        try type_params.append(self.allocator, tp_name.text(self.source));
                        try params.append(self.allocator, .{
                            .name = param_name.text(self.source),
                            .ty = .{ .type_param = .{ .name = tp_name.text(self.source), .span = spanFrom(tp_name, tp_name) } },
                            .span = spanFrom(param_name, tp_name),
                        });
                    } else {
                        const ty = try self.parseType();
                        try params.append(self.allocator, .{
                            .name = param_name.text(self.source),
                            .ty = ty,
                            .span = ty.span(),
                        });
                    }
                }
                if (!self.match(.comma)) break;
                if (self.check(.r_paren)) break;
            }
        }

        _ = try self.expect(.r_paren, "expected ) after parameters");
        const return_ty = if (self.match(.arrow)) try self.parseType() else namedType("void", Span.new(@intCast(name.start), @intCast(name.start + name.len)));
        // `-> $Acc`: an output type param computed by `where`. Register it as a
        // type param (if new) and record it as output.
        var output_type_params: std.ArrayList([]const u8) = .empty;
        errdefer output_type_params.deinit(self.allocator);
        if (return_ty == .type_param) {
            const nm = return_ty.type_param.name;
            var found = false;
            for (type_params.items) |tp| {
                if (std.mem.eql(u8, tp, nm)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try type_params.append(self.allocator, nm);
                try output_type_params.append(self.allocator, nm);
            }
        }
        const error_ty = if (self.match(.bang)) try self.parseErrorSpec(self.previous()) else null;
        // Optional `where` clause — either a `where { … }` resolve-time predicate
        // (comptime; may `reject`), or interface-conformance bounds
        // `where T: Iface, U: Iface2` (equivalent to writing `$T: Iface` inline).
        var where_clause: ?ast.Block = null;
        if (self.matchIdent("where")) {
            if (self.check(.l_brace)) {
                where_clause = try self.parseBlock();
            } else {
                while (true) {
                    const tp = try self.expect(.ident, "expected a type-parameter name in the `where` clause");
                    _ = try self.expect(.colon, "expected `:` after the type parameter in the `where` clause");
                    const iface = try self.expect(.ident, "expected an interface name after `:` in the `where` clause");
                    try type_constraints.append(self.allocator, .{
                        .param = tp.text(self.source),
                        .interface = iface.text(self.source),
                        .span = spanFrom(tp, iface),
                    });
                    if (!self.match(.comma)) break;
                }
            }
        }
        const body = if (self.check(.l_brace)) try self.parseBlock() else null;
        const end = if (body) |b| b.span else blk: {
            const semi = try self.expect(.semicolon, "expected ; after external function declaration");
            break :blk spanFrom(name, semi);
        };

        return .{
            .attrs = attrs,
            .name = name.text(self.source),
            .file_name = self.file_name,
            .source = self.source,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .output_type_params = try output_type_params.toOwnedSlice(self.allocator),
            .type_constraints = try type_constraints.toOwnedSlice(self.allocator),
            .params = try params.toOwnedSlice(self.allocator),
            .return_ty = return_ty,
            .error_ty = error_ty,
            .where_clause = where_clause,
            .body = body,
            .span = Span.new(name.start, end.end),
        };
    }

    fn parseBlock(self: *Parser) ParseError!ast.Block {
        const open = try self.expect(.l_brace, "expected {");
        var statements: std.ArrayList(ast.Stmt) = .empty;
        errdefer statements.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            try statements.append(self.allocator, try self.parseStmt());
        }

        const close = try self.expect(.r_brace, "expected } after block");
        return .{
            .statements = try statements.toOwnedSlice(self.allocator),
            .span = spanFrom(open, close),
        };
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        if (self.match(.keyword_return)) {
            const start = self.previous();
            const value = if (!self.check(.semicolon)) try self.parseExpr(0) else null;
            const semi = try self.expect(.semicolon, "expected ; after return");
            return .{ .return_stmt = .{ .value = value, .span = spanFrom(start, semi) } };
        }
        if (self.match(.keyword_fail)) return .{ .fail_stmt = try self.parseFail(self.previous()) };
        if (self.match(.keyword_break)) {
            const tok = self.previous();
            const semi = try self.expect(.semicolon, "expected ; after break");
            return .{ .break_stmt = spanFrom(tok, semi) };
        }
        if (self.match(.keyword_continue)) {
            const tok = self.previous();
            const semi = try self.expect(.semicolon, "expected ; after continue");
            return .{ .continue_stmt = spanFrom(tok, semi) };
        }
        if (self.match(.keyword_defer)) return .{ .defer_stmt = try self.parseDefer(self.previous()) };
        if (self.match(.keyword_match)) return .{ .match_stmt = try self.parseMatch(self.previous()) };
        // Compile-time directives: #if, #run
        if (self.match(.hash)) return try self.parseComptimeDirective(self.previous());
        if (self.match(.keyword_zone)) return .{ .zone_block = try self.parseZoneBlock(self.previous()) };
        if (self.match(.keyword_unsafe)) return .{ .unsafe_block = try self.parseBlock() };
        if (self.match(.keyword_if)) return .{ .if_stmt = try self.parseIf(self.previous()) };
        if (self.match(.keyword_while)) return .{ .while_stmt = try self.parseWhile(self.previous()) };
        if (self.match(.keyword_for)) return try self.parseFor(self.previous());

        if (self.check(.ident) and self.peekKind(1) == .colon_eq) {
            const name = self.advance();
            _ = self.advance();
            const value = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after local");
            return .{ .local_infer = .{
                .name = name.text(self.source),
                .value = value,
                .span = spanFrom(name, semi),
            } };
        }
        if (self.check(.ident) and self.peekKind(1) == .colon) {
            const name = self.advance();
            _ = self.advance();
            const ty = try self.parseType();
            _ = try self.expect(.eq, "expected = after typed local");
            const value = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after typed local");
            return .{ .local_typed = .{
                .name = name.text(self.source),
                .ty = ty,
                .value = value,
                .span = spanFrom(name, semi),
            } };
        }

        const statement_expr = try self.parseExpr(0);
        if (isAssignOp(self.peek().kind)) {
            const op_tok = self.advance();
            const op = assignOpFromToken(op_tok.kind);
            const value = try self.parseExpr(0);
            const semi = try self.expect(.semicolon, "expected ; after assignment");
            return .{ .assign = .{
                .target = statement_expr,
                .op = op,
                .value = value,
                .span = spanFrom(statement_expr.span, semi),
            } };
        }

        _ = try self.expect(.semicolon, "expected ; after expression");
        return .{ .expr = statement_expr };
    }

    fn parseIf(self: *Parser, start: Token) ParseError!ast.IfStmt {
        var binding: ?ast.IfBinding = null;
        var payload_binding: ?[]const u8 = null;
        var condition: ast.Expr = undefined;

        if (self.check(.ident) and self.peekKind(1) == .colon_eq) {
            const name = self.advance();
            _ = self.advance();
            const value = try self.parseExpr(0);
            binding = .{ .name = name.text(self.source), .value = value };
            condition = value;
        } else {
            condition = try self.parseExpr(0);
        }

        if (self.match(.pipe)) {
            const name = try self.expect(.ident, "expected error payload binding");
            _ = try self.expect(.pipe, "expected | after error payload binding");
            payload_binding = name.text(self.source);
        }

        const then_block = try self.parseBlock();
        // `else if …` desugars to `else { if … }` — wrap the nested if in a
        // one-statement block so the rest of the pipeline sees plain nesting.
        const else_block: ?ast.Block = if (self.match(.keyword_else)) blk: {
            if (self.check(.keyword_if)) {
                const if_kw = self.advance();
                const nested = try self.parseIf(if_kw);
                const stmts = try self.allocator.alloc(ast.Stmt, 1);
                stmts[0] = .{ .if_stmt = nested };
                break :blk ast.Block{ .statements = stmts, .span = nested.span };
            }
            break :blk try self.parseBlock();
        } else null;
        const end = if (else_block) |b| b.span else then_block.span;
        return .{ .binding = binding, .payload_binding = payload_binding, .condition = condition, .then_block = then_block, .else_block = else_block, .span = Span.new(start.start, end.end) };
    }

    fn parseDefer(self: *Parser, start: Token) ParseError!ast.DeferStmt {
        var mode: ast.DeferMode = .always;
        if (self.match(.dot)) {
            const mode_name = try self.expect(.ident, "expected defer mode");
            const text = mode_name.text(self.source);
            if (std.mem.eql(u8, text, "ok")) {
                mode = .ok;
            } else if (std.mem.eql(u8, text, "err")) {
                mode = .err;
            } else {
                try self.errorAt(mode_name, "expected ok or err after defer.");
                return error.ParseFailed;
            }
        }
        // defer { ... }  or  defer expr;
        if (self.check(.l_brace)) {
            const body = try self.parseBlock();
            return .{ .mode = mode, .body = body, .span = spanFrom(start, body.span) };
        }
        // Single expression statement — wrap in a one-stmt block
        const deferred_expr = try self.parseExpr(0);
        const semi = try self.expect(.semicolon, "expected ; after defer expression");
        const stmt_span = spanFrom(deferred_expr.span, semi);
        var stmts = std.ArrayList(ast.Stmt).empty;
        errdefer stmts.deinit(self.allocator);
        try stmts.append(self.allocator, .{ .expr = deferred_expr });
        const body = ast.Block{
            .statements = try stmts.toOwnedSlice(self.allocator),
            .span = stmt_span,
        };
        return .{ .mode = mode, .body = body, .span = spanFrom(start, semi) };
    }

    fn parseFail(self: *Parser, start: Token) ParseError!ast.FailStmt {
        _ = try self.expect(.dot, "expected .variant after fail");
        const variant = try self.expect(.ident, "expected error variant after fail .");
        var payload: []const ast.Expr = &.{};
        if (self.match(.l_brace)) {
            var values: std.ArrayList(ast.Expr) = .empty;
            errdefer values.deinit(self.allocator);
            if (!self.check(.r_brace)) {
                while (true) {
                    try values.append(self.allocator, try self.parseExpr(0));
                    if (!self.match(.comma)) break;
                    if (self.check(.r_brace)) break;
                }
            }
            _ = try self.expect(.r_brace, "expected } after error payload");
            payload = try values.toOwnedSlice(self.allocator);
        }
        const semi = try self.expect(.semicolon, "expected ; after fail");
        return .{ .variant = variant.text(self.source), .payload = payload, .span = spanFrom(start, semi) };
    }

    fn parseZoneBlock(self: *Parser, start: Token) ParseError!ast.ZoneBlock {
        const name = try self.expect(.ident, "expected zone name");
        _ = try self.expect(.colon, "expected : after zone name");
        const kind = try self.expect(.ident, "expected zone kind (Arena, Pool, ...)");
        const body = try self.parseBlock();
        return .{
            .name = name.text(self.source),
            .kind = kind.text(self.source),
            .body = body,
            .span = spanFrom(start, body.span),
        };
    }

    fn parseWhile(self: *Parser, start: Token) ParseError!ast.WhileStmt {
        const condition = try self.parseExpr(0);
        // `while opt |x| { … }` — unwrap the optional payload each iteration.
        var payload_binding: ?[]const u8 = null;
        if (self.match(.pipe)) {
            const name = try self.expect(.ident, "expected binding name after `|`");
            _ = try self.expect(.pipe, "expected `|` after the binding name");
            payload_binding = name.text(self.source);
        }
        const body = try self.parseBlock();
        return .{ .condition = condition, .payload_binding = payload_binding, .body = body, .span = Span.new(start.start, body.span.end) };
    }

    fn parseFor(self: *Parser, start: Token) ParseError!ast.Stmt {
        const by_ref = self.match(.amp);
        const binding = try self.expect(.ident, "expected loop binding");
        var index_binding: ?[]const u8 = null;
        if (self.match(.comma)) {
            const index = try self.expect(.ident, "expected index binding");
            index_binding = index.text(self.source);
        }
        _ = try self.expect(.keyword_in, "expected `in` after loop binding");

        const first = try self.parseExpr(0);
        if (self.match(.dot_dot) or self.match(.dot_dot_eq)) {
            if (by_ref or index_binding != null) {
                try self.errorAt(self.previous(), "range loops do not support reference or index bindings");
                return error.ParseFailed;
            }
            const inclusive = self.previous().kind == .dot_dot_eq;
            const end = try self.parseExpr(0);
            const body = try self.parseBlock();
            return .{ .for_range = .{
                .binding = binding.text(self.source),
                .start = first,
                .end = end,
                .inclusive = inclusive,
                .body = body,
                .span = Span.new(start.start, body.span.end),
            } };
        }

        const body = try self.parseBlock();
        return .{ .for_slice = .{
            .binding = binding.text(self.source),
            .index_binding = index_binding,
            .by_ref = by_ref,
            .iter = first,
            .body = body,
            .span = Span.new(start.start, body.span.end),
        } };
    }

    fn parseAttributes(self: *Parser) ParseError![]const ast.Attribute {
        var attrs: std.ArrayList(ast.Attribute) = .empty;
        errdefer attrs.deinit(self.allocator);

        while (self.check(.hash) and self.peekKind(1) != .keyword_import) {
            const hash = self.advance();
            const name = try self.expect(.ident, "expected attribute name");
            var args: []const ast.Expr = &.{};
            if (self.match(.l_paren)) {
                var list: std.ArrayList(ast.Expr) = .empty;
                errdefer list.deinit(self.allocator);
                if (!self.check(.r_paren)) {
                    while (true) {
                        try list.append(self.allocator, try self.parseExpr(0));
                        if (!self.match(.comma)) break;
                    }
                }
                _ = try self.expect(.r_paren, "expected ) after attribute");
                args = try list.toOwnedSlice(self.allocator);
            }
            try attrs.append(self.allocator, .{ .name = name.text(self.source), .args = args, .span = spanFrom(hash, name) });
        }

        return attrs.toOwnedSlice(self.allocator);
    }

    fn parsePath(self: *Parser) ParseError![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(self.allocator);

        try parts.append(self.allocator, (try self.expect(.ident, "expected path segment")).text(self.source));
        // Only consume `.ident` segments; leave a trailing `.{` (selective) or
        // `.*` (glob) for the import parser.
        while (self.peekKind(0) == .dot and self.peekKind(1) == .ident) {
            _ = self.advance(); // dot
            try parts.append(self.allocator, (try self.expect(.ident, "expected path segment")).text(self.source));
        }
        return parts.toOwnedSlice(self.allocator);
    }

    fn parseType(self: *Parser) ParseError!ast.TypeRef {
        const start = self.peek();
        if (self.match(.question)) {
            const inner = try self.allocType(try self.parseType());
            return .{ .optional = .{ .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.star)) {
            var is_const = false;
            var is_volatile = false;
            if (self.match(.keyword_const)) is_const = true;
            if (self.match(.keyword_volatile)) is_volatile = true;
            const inner = try self.allocType(try self.parseType());
            return .{ .pointer = .{ .is_const = is_const, .is_volatile = is_volatile, .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.l_bracket_star)) {
            _ = try self.expect(.r_bracket, "expected ] after [*");
            var is_const = false;
            if (self.match(.keyword_const)) is_const = true;
            const inner = try self.allocType(try self.parseType());
            return .{ .many_pointer = .{ .is_const = is_const, .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.l_bracket)) {
            if (self.match(.r_bracket)) {
                var is_const = false;
                if (self.match(.keyword_const)) is_const = true;
                const inner = try self.allocType(try self.parseType());
                return .{ .slice = .{ .is_const = is_const, .inner = inner, .span = Span.new(start.start, inner.span().end) } };
            }
            const len = try self.parseExpr(0);
            _ = try self.expect(.r_bracket, "expected ] after array length");
            const inner = try self.allocType(try self.parseType());
            return .{ .array = .{ .len = try self.allocExpr(len), .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.keyword_atomic)) {
            const inner = try self.allocType(try self.parseType());
            return .{ .atomic = .{ .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        if (self.match(.keyword_borrow)) {
            const inner = try self.allocType(try self.parseType());
            return .{ .borrow = .{ .inner = inner, .span = Span.new(start.start, inner.span().end) } };
        }
        // `extern fn(...)` — a thin C-ABI function pointer (contextual `extern`
        // prefix; `extern` is not otherwise a keyword). Plain `fn(...)` stays a
        // fat closure.
        const is_extern_fn = self.checkIdentAt(0, "extern") and self.peekKind(1) == .keyword_fn;
        if (is_extern_fn) _ = self.advance(); // consume `extern`
        if (is_extern_fn or self.match(.keyword_fn)) {
            if (is_extern_fn) _ = self.advance(); // consume `fn`
            _ = try self.expect(.l_paren, "expected ( after fn type");
            var params: std.ArrayList(ast.TypeRef) = .empty;
            errdefer params.deinit(self.allocator);
            if (!self.check(.r_paren)) {
                while (true) {
                    try params.append(self.allocator, try self.parseType());
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.r_paren, "expected ) after fn type params");
            // `-> ret` is optional: a fn type with no arrow returns `void`, just
            // like a fn declaration with no `->` (e.g. `fn(T)` is `fn(T) -> void`).
            const ret = if (self.match(.arrow))
                try self.allocType(try self.parseType())
            else
                try self.allocType(namedType("void", Span.new(start.start, start.start + start.len)));
            const error_ty = if (self.match(.bang)) try self.parseErrorSpec(self.previous()) else null;
            const end = if (error_ty) |err| err.span().end else ret.span().end;
            return .{ .fn_type = .{ .type_params = &.{}, .params = try params.toOwnedSlice(self.allocator), .ret = ret, .error_ty = error_ty, .is_extern = is_extern_fn, .span = Span.new(start.start, end) } };
        }
        if (self.match(.keyword_opaque)) return .opaque_type;

        // `$Acc` — a type parameter reference. In return position (`-> $Acc`)
        // this declares an *output* type param computed by the `where` clause.
        if (self.match(.dollar)) {
            const tp = try self.expect(.ident, "expected type-param name after $");
            return .{ .type_param = .{ .name = tp.text(self.source), .span = spanFrom(tp, tp) } };
        }

        const name = self.advance();
        if (!isTypeName(name.kind)) {
            try self.errorAt(name, "expected type");
            return error.ParseFailed;
        }
        // Namespace-qualified type: `ns::Name`. The base names an import alias
        // (`#import a.b;` → `b::Name`); the member is the actual type name. A
        // generic argument list may still follow (`ns::Name(args)`), handled
        // below exactly as for a bare name.
        var namespace: ?[]const u8 = null;
        var type_tok = name;
        if (self.match(.colon_colon)) {
            const member = try self.expect(.ident, "expected name after `::`");
            namespace = name.text(self.source);
            type_tok = member;
        }
        // Generic instantiation: Name(TypeArg1, TypeArg2, ...)
        if (self.match(.l_paren)) {
            var args: std.ArrayList(ast.TypeRef) = .empty;
            errdefer args.deinit(self.allocator);
            while (!self.check(.r_paren) and !self.check(.eof)) {
                try args.append(self.allocator, try self.parseType());
                if (!self.match(.comma)) break;
            }
            const close = try self.expect(.r_paren, "expected ) after type arguments");
            return .{ .generic_inst = .{
                .name = type_tok.text(self.source),
                .namespace = namespace,
                .args = try args.toOwnedSlice(self.allocator),
                .span = spanFrom(name, close),
            } };
        }
        return .{ .named = .{
            .name = type_tok.text(self.source),
            .namespace = namespace,
            .span = spanFrom(name, type_tok),
        } };
    }

    fn parseExpr(self: *Parser, min_bp: u8) ParseError!ast.Expr {
        var left = try self.parsePrefix();

        while (true) {
            if (self.match(.l_paren)) {
                left = try self.finishCall(left);
                continue;
            }
            if (self.match(.dot)) {
                const field = try self.expect(.ident, "expected field name");
                left = try self.expr(.{ .field = .{ .base = try self.allocExpr(left), .name = field.text(self.source) } }, Span.new(left.span.start, field.start + field.len));
                continue;
            }
            if (self.match(.colon_colon)) {
                const member = try self.expect(.ident, "expected name after `::`");
                left = try self.expr(.{ .scope_access = .{ .base = try self.allocExpr(left), .member = member.text(self.source) } }, Span.new(left.span.start, member.start + member.len));
                continue;
            }
            if (self.match(.l_bracket)) {
                if (self.match(.colon)) {
                    const close = try self.expect(.r_bracket, "expected ] after slice");
                    left = try self.expr(.{ .slice = .{ .base = try self.allocExpr(left) } }, Span.new(left.span.start, close.start + close.len));
                } else if (self.match(.dot_dot)) {
                    var end_expr: ?*const ast.Expr = null;
                    if (!self.check(.r_bracket)) {
                        end_expr = try self.allocExpr(try self.parseExpr(0));
                    }
                    const close = try self.expect(.r_bracket, "expected ] after slice");
                    left = try self.expr(.{ .slice = .{ .base = try self.allocExpr(left), .start = null, .end = end_expr } }, Span.new(left.span.start, close.start + close.len));
                } else {
                    const first = try self.parseExpr(0);
                    if (self.match(.dot_dot)) {
                        var end_expr: ?*const ast.Expr = null;
                        if (!self.check(.r_bracket)) {
                            end_expr = try self.allocExpr(try self.parseExpr(0));
                        }
                        const close = try self.expect(.r_bracket, "expected ] after slice");
                        left = try self.expr(.{ .slice = .{ .base = try self.allocExpr(left), .start = try self.allocExpr(first), .end = end_expr } }, Span.new(left.span.start, close.start + close.len));
                    } else {
                        const close = try self.expect(.r_bracket, "expected ] after index");
                        left = try self.expr(.{ .index = .{ .base = try self.allocExpr(left), .index = try self.allocExpr(first) } }, Span.new(left.span.start, close.start + close.len));
                    }
                }
                continue;
            }
            if (self.match(.l_bracket_colon)) {
                const close = try self.expect(.r_bracket, "expected ] after slice");
                left = try self.expr(.{ .slice = .{ .base = try self.allocExpr(left) } }, Span.new(left.span.start, close.start + close.len));
                continue;
            }
            // expr?  — propagate error
            if (self.match(.question)) {
                const end = self.previous();
                left = try self.expr(.{ .try_expr = .{ .value = try self.allocExpr(left) } }, Span.new(left.span.start, end.start + end.len));
                continue;
            }
            // expr!! — force unwrap (panic if null/error)
            if (self.match(.bang_bang)) {
                const end = self.previous();
                left = try self.expr(.{ .force_unwrap = try self.allocExpr(left) }, Span.new(left.span.start, end.start + end.len));
                continue;
            }
            if (self.match(.keyword_as)) {
                const dest_ty = try self.parseType();
                left = try self.expr(.{ .as_cast = .{
                    .value = try self.allocExpr(left),
                    .to = dest_ty,
                } }, Span.new(left.span.start, dest_ty.span().end));
                continue;
            }
            // expr ?? default — nil coalesce
            if (self.match(.question_question)) {
                const default = try self.parseExpr(1); // right-associative, same precedence as ??
                left = try self.expr(.{ .nil_coalesce = .{
                    .value = try self.allocExpr(left),
                    .default = try self.allocExpr(default),
                } }, Span.new(left.span.start, default.span.end));
                continue;
            }
            if (self.match(.keyword_catch)) {
                const err_name = try self.expect(.ident, "expected error binding after catch");
                const handler = try self.parseBlock();
                left = try self.expr(.{ .catch_expr = .{ .value = try self.allocExpr(left), .err_name = err_name.text(self.source), .handler = handler } }, Span.new(left.span.start, handler.span.end));
                continue;
            }

            // Stop before |name| { — that is the payload capture in `if cond |name| { }`,
            // not a bitwise-OR chain.  The l_brace at position +3 distinguishes this from
            // a genuine `a | b | c` expression where position +3 would be another ident or operator.
            if (self.check(.pipe) and
                self.peekKind(1) == .ident and
                self.peekKind(2) == .pipe and
                self.peekKind(3) == .l_brace) break;
            const info = infixInfo(self.peek().kind) orelse break;
            if (info.left_bp < min_bp) break;
            _ = self.advance();
            const right = try self.parseExpr(info.right_bp);
            left = try self.expr(.{ .binary = .{ .op = info.op, .left = try self.allocExpr(left), .right = try self.allocExpr(right) } }, Span.new(left.span.start, right.span.end));
        }

        return left;
    }

    fn parsePrefix(self: *Parser) ParseError!ast.Expr {
        const tok = self.advance();
        switch (tok.kind) {
            .ident => return self.expr(.{ .ident = tok.text(self.source) }, spanFrom(tok, tok)),
            .keyword_bool,
            .keyword_void,
            .keyword_i8,
            .keyword_i16,
            .keyword_i32,
            .keyword_i64,
            .keyword_isize,
            .keyword_u8,
            .keyword_u16,
            .keyword_u32,
            .keyword_u64,
            .keyword_usize,
            .keyword_atomic,
            .keyword_borrow,
            .question,
            .l_bracket,
            .l_bracket_star,
            => {
                self.index -= 1;
                const ty = try self.parseType();
                return self.expr(.{ .type_ref = ty }, ty.span());
            },
            .int_lit => return self.expr(.{ .int = tok.text(self.source) }, spanFrom(tok, tok)),
            .float_lit => return self.expr(.{ .float = tok.text(self.source) }, spanFrom(tok, tok)),
            .string_lit => return self.expr(.{ .string = tok.text(self.source) }, spanFrom(tok, tok)),
            .char_lit => {
                // A char literal is just sugar for its integer code point — an
                // untyped int literal that coerces to u8/rune/i32/etc. like `65`.
                const value = decodeCharLit(tok.text(self.source)) catch {
                    try self.errorAt(tok, "invalid character literal");
                    return error.ParseFailed;
                };
                const dec = std.fmt.allocPrint(self.allocator, "{d}", .{value}) catch return error.ParseFailed;
                return self.expr(.{ .int = dec }, spanFrom(tok, tok));
            },
            .keyword_true => return self.expr(.{ .bool = true }, spanFrom(tok, tok)),
            .keyword_false => return self.expr(.{ .bool = false }, spanFrom(tok, tok)),
            .keyword_null => return self.expr(.null, spanFrom(tok, tok)),
            .keyword_volatile => return self.expr(.{ .ident = tok.text(self.source) }, spanFrom(tok, tok)),
            .keyword_unsafe => {
                const inner = try self.parseExpr(8);
                return self.expr(
                    .{ .unsafe_expr = try self.allocExpr(inner) },
                    Span.new(tok.start, inner.span.end),
                );
            },
            .keyword_fn => {
                // `fn(…) [-> R] { body }` — a lambda (anonymous function),
                // distinguished from a fn *type* in value position (`fn(T) -> R`,
                // a builtin type-arg) by a trailing `{ body }`.
                if (self.lambdaAhead()) {
                    return self.parseLambda(tok);
                }
                self.index -= 1; // un-consume `fn`; re-parse as a fn type value
                const ty = try self.parseType();
                return self.expr(.{ .type_ref = ty }, ty.span());
            },
            // `match subject { pattern => value, ... }` as a value expression.
            .keyword_match => return self.parseMatchExpr(tok),
            // `if cond { value } else { value }` as a value expression. (Statement
            // position is intercepted by the statement parser, so this only fires
            // when `if` is parsed as an operand — after `:=`/`=`/`return`/in args.)
            .keyword_if => return self.parseIfExpr(tok),
            // #run expr — compile-time expression in value position
            .hash => {
                if (self.matchIdent("run")) {
                    const inner = try self.parseExpr(18);
                    return self.expr(
                        .{ .run_expr = try self.allocExpr(inner) },
                        Span.new(tok.start, inner.span.end),
                    );
                }
                // #parse(expr) — parse a comptime string as code.
                if (self.matchIdent("parse")) {
                    _ = try self.expect(.l_paren, "expected ( after #parse");
                    const inner = try self.parseExpr(0);
                    const close = try self.expect(.r_paren, "expected ) after #parse expression");
                    return self.expr(.{ .parse_expr = try self.allocExpr(inner) }, Span.new(tok.start, close.start + close.len));
                }
                // #quote { ... } — block quotation;  #quote(expr) — expr form.
                if (self.matchIdent("quote")) {
                    if (self.check(.l_paren)) {
                        _ = self.advance(); // consume (
                        const inner = try self.parseExpr(0);
                        const close = try self.expect(.r_paren, "expected ) after #quote expression");
                        return self.expr(.{ .quote_expr = try self.allocExpr(inner) }, Span.new(tok.start, close.start + close.len));
                    }
                    const block = try self.parseBlock();
                    return self.expr(.{ .quote = block }, Span.new(tok.start, block.span.end));
                }
                try self.errorAt(tok, "expected 'run' or 'quote' after # in expression position");
                return error.ParseFailed;
            },
            // $name / $(expr) — a splice hole inside a #quote (macro template).
            .dollar => {
                if (self.match(.l_paren)) {
                    const inner = try self.parseExpr(0);
                    const close = try self.expect(.r_paren, "expected ) after $( splice");
                    return self.expr(.{ .splice = try self.allocExpr(inner) }, Span.new(tok.start, close.start + close.len));
                }
                const name = try self.expect(.ident, "expected name or ( after $");
                const inner = try self.expr(.{ .ident = name.text(self.source) }, spanFrom(name, name));
                return self.expr(.{ .splice = try self.allocExpr(inner) }, spanFrom(tok, name));
            },
            .dot => {
                const name = try self.expect(.ident, "expected name after .");
                return self.expr(.{ .ident = self.source[tok.start .. name.start + name.len] }, spanFrom(tok, name));
            },
            .bang => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .not, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .tilde => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .bit_not, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .amp => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .address_of, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .star => {
                // `*p` — a dereference. A pointer *type* in value position
                // (`ptr_from_int(*Chunk, p)`, `sizeof(*u8)`) only ever appears as
                // a call argument and is disambiguated there (parseCallArgExpr);
                // in every other position — grouping `(*p)`, `unsafe (*p)`,
                // `*p + 1`, `return *p` — a leading `*` is unambiguously a load.
                // Bind as tightly as the other prefix operators (`&`, `-`, `!`),
                // so `*p + 1` is `(*p) + 1`, not `*(p + 1)`.
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .deref, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .minus => {
                const operand = try self.parseExpr(18);
                return self.expr(.{ .unary = .{ .op = .neg, .expr = try self.allocExpr(operand) } }, Span.new(tok.start, operand.span.end));
            },
            .l_paren => {
                const inner = try self.parseExpr(0);
                _ = try self.expect(.r_paren, "expected )");
                return inner;
            },
            .dot_lbrace => return self.finishCompound(tok),
            .l_brace => {
                _ = try self.expect(.r_brace, "expected }");
                return self.expr(.{ .compound_literal = &.{} }, spanFrom(tok, self.previous()));
            },
            else => {
                try self.errorAt(tok, "expected expression");
                return error.ParseFailed;
            },
        }
    }

    fn finishCompound(self: *Parser, start: Token) ParseError!ast.Expr {
        // Named struct literal: `.{ .x = 1, .y = 2 }`. Detected by a leading
        // `.<ident> =`. (`.{ .red, .green }` — bare enum values — has no `=`, so it
        // stays a positional literal.)
        if (self.check(.dot) and self.peekKind(1) == .ident and self.peekKind(2) == .eq) {
            var fields: std.ArrayList(ast.FieldInit) = .empty;
            errdefer fields.deinit(self.allocator);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                _ = try self.expect(.dot, "expected `.field` in struct literal");
                const name = try self.expect(.ident, "expected field name after `.`");
                _ = try self.expect(.eq, "expected `=` after `.field` in struct literal");
                const value = try self.parseExpr(0);
                try fields.append(self.allocator, .{
                    .name = name.text(self.source),
                    .value = value,
                    .span = spanFrom(name, self.previous()),
                });
                _ = self.match(.comma);
            }
            const close = try self.expect(.r_brace, "expected } after struct literal");
            return self.expr(.{ .struct_literal = try fields.toOwnedSlice(self.allocator) }, spanFrom(start, close));
        }
        var values: std.ArrayList(ast.Expr) = .empty;
        errdefer values.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try values.append(self.allocator, try self.parseExpr(0));
            _ = self.match(.comma);
        }
        const close = try self.expect(.r_brace, "expected } after compound literal");
        return self.expr(.{ .compound_literal = try values.toOwnedSlice(self.allocator) }, spanFrom(start, close));
    }

    // Parse a single call argument. A leading `*Type` here is a pointer *type*
    // passed to a builtin (`sizeof(*u8)`, `ptr_from_int(*Chunk, p)`) — the one
    // place a type appears in value position. Elsewhere `*x` is a dereference
    // (handled by the generic prefix parser).
    fn parseCallArgExpr(self: *Parser) ParseError!ast.Expr {
        if (self.check(.star)) {
            const k1 = self.peekKind(1);
            const looks_like_type = (k1 == .keyword_const or k1 == .keyword_volatile) or
                (isTypeName(k1) and switch (self.peekKind(2)) {
                    .comma, .r_paren => true,
                    else => false,
                });
            if (looks_like_type) {
                const ty = try self.parseType();
                return self.expr(.{ .type_ref = ty }, ty.span());
            }
        }
        return self.parseExpr(0);
    }

    fn finishCall(self: *Parser, callee: ast.Expr) ParseError!ast.Expr {
        var args: std.ArrayList(ast.CallArg) = .empty;
        errdefer args.deinit(self.allocator);
        if (!self.check(.r_paren)) {
            while (true) {
                if (self.check(.ident) and self.peekKind(1) == .colon) {
                    const name = self.advance();
                    _ = self.advance();
                    // Named arg value: parse a full compound literal `{ ... }` or a regular expression.
                    const value = if (self.check(.l_brace)) try self.finishCompound(self.advance()) else try self.parseCallArgExpr();
                    try args.append(self.allocator, .{ .named = .{ .name = name.text(self.source), .value = value } });
                } else {
                    try args.append(self.allocator, .{ .positional = try self.parseCallArgExpr() });
                }
                if (!self.match(.comma)) break;
                if (self.check(.r_paren)) break;
            }
        }
        const close = try self.expect(.r_paren, "expected ) after call");
        return self.expr(.{ .call = .{ .callee = try self.allocExpr(callee), .args = try args.toOwnedSlice(self.allocator) } }, Span.new(callee.span.start, close.start + close.len));
    }

    fn expr(self: *Parser, kind: ast.ExprKind, span: Span) !ast.Expr {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .kind = kind, .span = span };
    }

    fn allocExpr(self: *Parser, value: ast.Expr) !*const ast.Expr {
        const ptr = try self.allocator.create(ast.Expr);
        ptr.* = value;
        return ptr;
    }

    fn allocType(self: *Parser, value: ast.TypeRef) !*const ast.TypeRef {
        const ptr = try self.allocator.create(ast.TypeRef);
        ptr.* = value;
        return ptr;
    }

    fn matchIdent(self: *Parser, text: []const u8) bool {
        if (!self.check(.ident)) return false;
        if (!std.mem.eql(u8, self.peek().text(self.source), text)) return false;
        _ = self.advance();
        return true;
    }

    /// True if the token `offset` positions ahead is an identifier with the
    /// given text, without consuming anything.
    fn checkIdentAt(self: Parser, offset: usize, text: []const u8) bool {
        if (self.peekKind(offset) != .ident) return false;
        const tok = self.tokens[@min(self.index + offset, self.tokens.len - 1)];
        return std.mem.eql(u8, tok.text(self.source), text);
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (!self.check(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn check(self: Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn peek(self: Parser) Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn peekKind(self: Parser, offset: usize) TokenKind {
        return self.tokens[@min(self.index + offset, self.tokens.len - 1)].kind;
    }

    fn previous(self: Parser) Token {
        return self.tokens[self.index - 1];
    }

    fn advance(self: *Parser) Token {
        const tok = self.peek();
        if (tok.kind != .eof) self.index += 1;
        return tok;
    }

    fn expect(self: *Parser, kind: TokenKind, message: []const u8) ParseError!Token {
        if (self.check(kind)) return self.advance();
        try self.errorAt(self.peek(), message);
        return error.ParseFailed;
    }

    fn errorAt(self: *Parser, tok: Token, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, Diagnostic.err(message, spanFrom(tok, tok), self.file_name));
    }
};

/// Strips surrounding double-quotes from a string-literal token's raw text.
fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

/// Decode a char-literal token (`'a'`, `'\n'`, `'\x41'`) — quotes included — to
/// its Unicode code point. Supports the usual escapes and `\xNN`; a bare
/// (possibly multi-byte UTF-8) character decodes to its code point.
fn decodeCharLit(raw: []const u8) !u32 {
    if (raw.len < 3 or raw[0] != '\'' or raw[raw.len - 1] != '\'') return error.Invalid;
    const inner = raw[1 .. raw.len - 1];
    if (inner.len == 0) return error.Invalid;
    if (inner[0] != '\\') {
        const n = std.unicode.utf8ByteSequenceLength(inner[0]) catch return error.Invalid;
        if (n == 1) return inner[0];
        if (inner.len < n) return error.Invalid;
        return std.unicode.utf8Decode(inner[0..n]) catch error.Invalid;
    }
    if (inner.len < 2) return error.Invalid;
    return switch (inner[1]) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '0' => 0,
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        'x' => blk: {
            if (inner.len < 4) return error.Invalid;
            const hi = std.fmt.charToDigit(inner[2], 16) catch return error.Invalid;
            const lo = std.fmt.charToDigit(inner[3], 16) catch return error.Invalid;
            break :blk @as(u32, hi) * 16 + lo;
        },
        else => error.Invalid,
    };
}

const Infix = struct {
    left_bp: u8,
    right_bp: u8,
    op: ast.BinaryOp,
};

fn infixInfo(kind: TokenKind) ?Infix {
    return switch (kind) {
        // Logical
        .pipe_pipe => .{ .left_bp = 1, .right_bp = 2, .op = .or_or },
        .amp_amp => .{ .left_bp = 3, .right_bp = 4, .op = .and_and },
        // Comparison
        .eq_eq => .{ .left_bp = 5, .right_bp = 6, .op = .equal },
        .bang_eq => .{ .left_bp = 5, .right_bp = 6, .op = .not_equal },
        .lt => .{ .left_bp = 5, .right_bp = 6, .op = .less },
        .lt_eq => .{ .left_bp = 5, .right_bp = 6, .op = .le },
        .gt => .{ .left_bp = 5, .right_bp = 6, .op = .gt },
        .gt_eq => .{ .left_bp = 5, .right_bp = 6, .op = .ge },
        // Bitwise
        .pipe => .{ .left_bp = 7, .right_bp = 8, .op = .bit_or },
        .caret => .{ .left_bp = 9, .right_bp = 10, .op = .bit_xor },
        .amp => .{ .left_bp = 11, .right_bp = 12, .op = .bit_and },
        // Shift
        .lt_lt => .{ .left_bp = 13, .right_bp = 14, .op = .shl },
        .gt_gt => .{ .left_bp = 13, .right_bp = 14, .op = .shr },
        // Additive
        .plus => .{ .left_bp = 15, .right_bp = 16, .op = .add },
        .minus => .{ .left_bp = 15, .right_bp = 16, .op = .sub },
        .plus_percent => .{ .left_bp = 15, .right_bp = 16, .op = .wrap_add },
        .minus_percent => .{ .left_bp = 15, .right_bp = 16, .op = .wrap_sub },
        // Multiplicative
        .star => .{ .left_bp = 17, .right_bp = 18, .op = .mul },
        .slash => .{ .left_bp = 17, .right_bp = 18, .op = .div },
        .percent => .{ .left_bp = 17, .right_bp = 18, .op = .rem },
        .star_percent => .{ .left_bp = 17, .right_bp = 18, .op = .wrap_mul },
        else => null,
    };
}

fn isTypeName(kind: TokenKind) bool {
    return switch (kind) {
        .ident,
        .keyword_bool,
        .keyword_void,
        .keyword_i8,
        .keyword_i16,
        .keyword_i32,
        .keyword_i64,
        .keyword_isize,
        .keyword_u8,
        .keyword_u16,
        .keyword_u32,
        .keyword_u64,
        .keyword_usize,
        => true,
        else => false,
    };
}

fn isAssignOp(kind: TokenKind) bool {
    return switch (kind) {
        .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq => true,
        else => false,
    };
}

fn assignOpFromToken(kind: TokenKind) ast.AssignOp {
    return switch (kind) {
        .eq => .assign,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .rem,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        .lt_lt_eq => .shl,
        .gt_gt_eq => .shr,
        else => unreachable,
    };
}

fn namedType(name: []const u8, span: Span) ast.TypeRef {
    return .{ .named = .{ .name = name, .span = span } };
}

fn isOneOf(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// A field whose type is a NAMED user type (a struct), not a builtin scalar — so a
/// derive should recurse into the field's own impl (`.eq`) rather than use `==`.
fn fieldIsNamedStruct(ty: ast.TypeRef, tps: []const []const u8) bool {
    return switch (ty) {
        .named => |n| {
            if (n.namespace != null) return false;
            // A generic type parameter (`value: T`) isn't known to be a struct —
            // could be `i32`, which has no `.eq` — so compare it with `==`.
            for (tps) |tp| if (std.mem.eql(u8, tp, n.name)) return false;
            return !isOneOf(n.name, &.{
                "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
                "f32", "f64", "bool", "byte", "usize", "isize", "rune", "addr", "void", "Self",
            });
        },
        else => false,
    };
}

fn spanFrom(start: anytype, end: anytype) Span {
    const s = if (@TypeOf(start) == Span) start.start else start.start;
    const e = if (@TypeOf(end) == Span) end.end else end.start + end.len;
    return Span.new(s, e);
}
