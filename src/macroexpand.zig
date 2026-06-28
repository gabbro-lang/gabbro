const std = @import("std");
const ast = @import("ast.zig");
const Span = @import("lexer/span.zig").Span;

// Macro expansion — Phase 2, template macros. Runs once, before sema. A
// `name :: macro(params) { return #quote { ... }; }` is a compile-time AST template.
// At each `#insert name(args);` we substitute the arg ASTs into the template's $param
// holes, rename the template's locals for hygiene, and rewrite the #insert to a literal
// #quote { <result> } that the front-end re-checks. Macro decls are dropped afterward,
// never lowered.
//
// It's deliberately a template engine: a macro body must be one `return #quote {...}`.
// Macros that RUN code (loops/logic) to build the AST are a later slice.

pub const ExpandError = error{ SemanticFailed, OutOfMemory };

/// Bindings from a macro's parameter names to the caller's argument ASTs.
const Env = std.StringHashMap(ast.Expr);
/// Hygiene: a template-introduced local name → its fresh, collision-free name.
const Hyg = std.StringHashMap([]const u8);

const Expander = struct {
    arena: std.mem.Allocator,
    macros: std.StringHashMap(ast.FunctionDecl),
    /// Monotonic counter so each expansion's hygienic names are distinct.
    gensym: u32 = 0,

    fn fail(comptime fmt: []const u8, args: anytype) ExpandError {
        std.debug.print("error: " ++ fmt ++ "\n", args);
        return error.SemanticFailed;
    }

    fn dup(self: *Expander, e: ast.Expr) ExpandError!*const ast.Expr {
        const p = try self.arena.create(ast.Expr);
        p.* = e;
        return p;
    }

    // module walk: collect macros, expand bodies, drop macro decls

    fn expandModule(self: *Expander, module: ast.Module) ExpandError!ast.Module {
        for (module.items) |item| switch (item) {
            .function => |f| if (f.is_macro) try self.macros.put(f.name, f),
            else => {},
        };

        var out: std.ArrayList(ast.Item) = .empty;
        for (module.items) |item| switch (item) {
            .function => |f| {
                if (f.is_macro) continue; // dropped — never lowered
                var nf = f;
                if (f.body) |body| nf.body = try self.expandBlock(body);
                try out.append(self.arena, .{ .function = nf });
            },
            .interface_impl => |impl| {
                var methods: std.ArrayList(ast.FunctionDecl) = .empty;
                for (impl.methods) |m| {
                    var nm = m;
                    if (m.body) |body| nm.body = try self.expandBlock(body);
                    try methods.append(self.arena, nm);
                }
                var ni = impl;
                ni.methods = try methods.toOwnedSlice(self.arena);
                try out.append(self.arena, .{ .interface_impl = ni });
            },
            else => try out.append(self.arena, item),
        };

        return .{ .file_name = module.file_name, .items = try out.toOwnedSlice(self.arena) };
    }

    /// Walk a block, rewriting any `#insert <macrocall>` (and recursing into
    /// nested blocks) — everything else is structurally preserved.
    fn expandBlock(self: *Expander, block: ast.Block) ExpandError!ast.Block {
        var out: std.ArrayList(ast.Stmt) = .empty;
        for (block.statements) |stmt| try self.expandStmt(stmt, &out);
        return .{ .statements = try out.toOwnedSlice(self.arena), .span = block.span };
    }

    fn expandStmt(self: *Expander, stmt: ast.Stmt, out: *std.ArrayList(ast.Stmt)) ExpandError!void {
        switch (stmt) {
            .insert_stmt => |ins| {
                // `#insert macrocall(args);` → expand to `#insert #quote { ... }`.
                if (ins.operand.kind == .call) {
                    const call = ins.operand.kind.call;
                    if (call.callee.kind == .ident) {
                        if (self.macros.get(call.callee.kind.ident)) |macro| {
                            const expanded = try self.expandMacroCall(macro, call);
                            // Recurse so a macro that itself uses #insert expands too.
                            const inner = try self.expandBlock(expanded);
                            const q = ast.Expr{ .id = ins.operand.id, .kind = .{ .quote = inner }, .span = ins.span };
                            try out.append(self.arena, .{ .insert_stmt = .{ .operand = q, .span = ins.span } });
                            return;
                        }
                    }
                }
                // `#insert #quote { ... }` (slice-1 literal) — recurse into it.
                if (ins.operand.kind == .quote) {
                    const inner = try self.expandBlock(ins.operand.kind.quote);
                    const q = ast.Expr{ .id = ins.operand.id, .kind = .{ .quote = inner }, .span = ins.operand.span };
                    try out.append(self.arena, .{ .insert_stmt = .{ .operand = q, .span = ins.span } });
                    return;
                }
                try out.append(self.arena, stmt); // sema rejects non-quote operands
            },
            // Recurse into block-bearing statements so nested #insert expands.
            .if_stmt => |s| {
                var n = s;
                n.then_block = try self.expandBlock(s.then_block);
                if (s.else_block) |eb| n.else_block = try self.expandBlock(eb);
                try out.append(self.arena, .{ .if_stmt = n });
            },
            .while_stmt => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .while_stmt = n });
            },
            .for_range => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .for_range = n });
            },
            .for_slice => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .for_slice = n });
            },
            .match_stmt => |s| {
                var arms: std.ArrayList(ast.MatchArm) = .empty;
                for (s.arms) |arm| {
                    var na = arm;
                    na.body = try self.expandBlock(arm.body);
                    try arms.append(self.arena, na);
                }
                var n = s;
                n.arms = try arms.toOwnedSlice(self.arena);
                try out.append(self.arena, .{ .match_stmt = n });
            },
            .zone_block => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .zone_block = n });
            },
            .defer_stmt => |s| {
                var n = s;
                n.body = try self.expandBlock(s.body);
                try out.append(self.arena, .{ .defer_stmt = n });
            },
            .unsafe_block => |b| try out.append(self.arena, .{ .unsafe_block = try self.expandBlock(b) }),
            .comptime_run => |b| try out.append(self.arena, .{ .comptime_run = try self.expandBlock(b) }),
            // `#for i in a..b { ... }` in ordinary code: unroll with literal
            // bounds, then re-expand each emitted statement (nested #insert/#for).
            .comptime_for => |cf| {
                var env = Env.init(self.arena);
                var hyg = Hyg.init(self.arena);
                var tmp: std.ArrayList(ast.Stmt) = .empty;
                try self.unrollFor(cf, &env, &hyg, &tmp);
                for (tmp.items) |s| try self.expandStmt(s, out);
            },
            .comptime_if => |s| {
                var n = s;
                n.then_block = try self.expandBlock(s.then_block);
                if (s.else_block) |eb| n.else_block = try self.expandBlock(eb);
                try out.append(self.arena, .{ .comptime_if = n });
            },
            else => try out.append(self.arena, stmt),
        }
    }

    // macro expansion: bind args, build hygiene map, substitute

    fn expandMacroCall(self: *Expander, macro: ast.FunctionDecl, call: ast.CallExpr) ExpandError!ast.Block {
        if (call.args.len != macro.params.len) {
            return fail("macro `{s}` expects {d} argument(s), but {d} were provided", .{ macro.name, macro.params.len, call.args.len });
        }

        var env = Env.init(self.arena);
        for (macro.params, call.args) |param, arg| {
            const arg_expr = switch (arg) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            try checkMacroArgType(macro.name, param, arg_expr);
            try env.put(param.name, arg_expr);
        }

        const template = try macroTemplate(macro);

        // Hygiene: collect the template's own locals and assign fresh names.
        var hyg = Hyg.init(self.arena);
        try self.collectIntroduced(template, &hyg);

        return self.substBlock(template, &env, &hyg);
    }

    /// Enforce typed macro parameters. `AstBlock`/`Block` require a block quote
    /// (`#quote { ... }`); `AstExpr`/`Expr` require an expression (not a block);
    /// `Code` (or any other type) accepts any argument.
    fn checkMacroArgType(macro_name: []const u8, param: ast.Param, arg: ast.Expr) ExpandError!void {
        const ty_name = switch (param.ty) {
            .named, .type_param => |n| n.name,
            else => return,
        };
        const wants_block = std.mem.eql(u8, ty_name, "AstBlock") or std.mem.eql(u8, ty_name, "Block");
        const wants_expr = std.mem.eql(u8, ty_name, "AstExpr") or std.mem.eql(u8, ty_name, "Expr");
        if (wants_block and arg.kind != .quote) {
            return fail("macro `{s}` parameter `{s}` expects a `#quote {{ ... }}` block", .{ macro_name, param.name });
        }
        if (wants_expr and arg.kind == .quote) {
            return fail("macro `{s}` parameter `{s}` expects an expression, not a `#quote {{ ... }}` block", .{ macro_name, param.name });
        }
    }

    /// A template macro's body must be a single `return #quote { ... };`.
    fn macroTemplate(macro: ast.FunctionDecl) ExpandError!ast.Block {
        const body = macro.body orelse return fail("macro `{s}` has no body", .{macro.name});
        for (body.statements) |stmt| switch (stmt) {
            .return_stmt => |ret| {
                const value = ret.value orelse continue;
                if (value.kind == .quote) return value.kind.quote;
                return fail("macro `{s}` must `return` a `#quote {{ ... }}` block", .{macro.name});
            },
            else => {},
        };
        return fail("macro `{s}` must contain `return #quote {{ ... }};`", .{macro.name});
    }

    fn collectIntroduced(self: *Expander, block: ast.Block, hyg: *Hyg) ExpandError!void {
        for (block.statements) |stmt| switch (stmt) {
            .local_infer => |l| try self.introduce(l.name, hyg),
            .local_typed => |l| try self.introduce(l.name, hyg),
            // Bindings a statement introduces (loop var, `|x|` capture) are locals
            // too — collect them so they're renamed and can't capture the caller's.
            .if_stmt => |s| {
                if (s.binding) |b| try self.introduce(b.name, hyg);
                if (s.payload_binding) |pb| try self.introduce(pb, hyg);
                try self.collectIntroduced(s.then_block, hyg);
                if (s.else_block) |eb| try self.collectIntroduced(eb, hyg);
            },
            .while_stmt => |s| try self.collectIntroduced(s.body, hyg),
            .for_range => |s| {
                try self.introduce(s.binding, hyg);
                try self.collectIntroduced(s.body, hyg);
            },
            .for_slice => |s| {
                try self.introduce(s.binding, hyg);
                if (s.index_binding) |ib| try self.introduce(ib, hyg);
                try self.collectIntroduced(s.body, hyg);
            },
            .match_stmt => |s| for (s.arms) |arm| {
                if (arm.binding) |b| try self.introduce(b, hyg);
                if (arm.pattern == .binding) try self.introduce(arm.pattern.binding, hyg);
                try self.collectIntroduced(arm.body, hyg);
            },
            .zone_block => |s| {
                try self.introduce(s.name, hyg);
                try self.collectIntroduced(s.body, hyg);
            },
            .defer_stmt => |s| try self.collectIntroduced(s.body, hyg),
            .comptime_if => |s| {
                try self.collectIntroduced(s.then_block, hyg);
                if (s.else_block) |eb| try self.collectIntroduced(eb, hyg);
            },
            .unsafe_block => |b| try self.collectIntroduced(b, hyg),
            .comptime_run => |b| try self.collectIntroduced(b, hyg),
            else => {},
        };
    }

    fn introduce(self: *Expander, name: []const u8, hyg: *Hyg) ExpandError!void {
        if (hyg.contains(name)) return;
        // `$` cannot appear in a user identifier, so this name can never collide.
        const fresh = try std.fmt.allocPrint(self.arena, "{s}$m{d}", .{ name, self.gensym });
        self.gensym += 1;
        try hyg.put(name, fresh);
    }

    // substitution

    fn substBlock(self: *Expander, block: ast.Block, env: *Env, hyg: *Hyg) ExpandError!ast.Block {
        var out: std.ArrayList(ast.Stmt) = .empty;
        for (block.statements) |stmt| try self.substStmt(stmt, env, hyg, &out);
        return .{ .statements = try out.toOwnedSlice(self.arena), .span = block.span };
    }

    fn substStmt(self: *Expander, stmt: ast.Stmt, env: *Env, hyg: *Hyg, out: *std.ArrayList(ast.Stmt)) ExpandError!void {
        // Block splice: a bare `$body;` statement whose param is bound to a
        // `#quote { ... }` argument inlines that block's statements verbatim.
        if (stmt == .expr and stmt.expr.kind == .splice) {
            const inner = stmt.expr.kind.splice.*;
            if (inner.kind == .ident) {
                if (env.get(inner.kind.ident)) |arg| {
                    if (arg.kind == .quote) {
                        for (arg.kind.quote.statements) |s| try out.append(self.arena, s);
                        return;
                    }
                }
            }
        }

        switch (stmt) {
            .local_infer => |l| try out.append(self.arena, .{ .local_infer = .{
                .name = self.rename(l.name, hyg),
                .value = try self.substExpr(l.value, env, hyg),
                .span = l.span,
            } }),
            .local_typed => |l| try out.append(self.arena, .{ .local_typed = .{
                .name = self.rename(l.name, hyg),
                .ty = try self.substType(l.ty, env),
                .value = try self.substExpr(l.value, env, hyg),
                .span = l.span,
            } }),
            .assign => |a| try out.append(self.arena, .{ .assign = .{
                .target = try self.substExpr(a.target, env, hyg),
                .op = a.op,
                .value = try self.substExpr(a.value, env, hyg),
                .span = a.span,
            } }),
            .return_stmt => |r| try out.append(self.arena, .{ .return_stmt = .{
                .value = if (r.value) |v| try self.substExpr(v, env, hyg) else null,
                .span = r.span,
            } }),
            .fail_stmt => |s| {
                var payload: std.ArrayList(ast.Expr) = .empty;
                for (s.payload) |e| try payload.append(self.arena, try self.substExpr(e, env, hyg));
                try out.append(self.arena, .{ .fail_stmt = .{ .variant = s.variant, .payload = try payload.toOwnedSlice(self.arena), .span = s.span } });
            },
            .if_stmt => |s| try out.append(self.arena, .{ .if_stmt = .{
                .binding = if (s.binding) |b| ast.IfBinding{ .name = self.rename(b.name, hyg), .value = try self.substExpr(b.value, env, hyg) } else null,
                .payload_binding = if (s.payload_binding) |pb| self.rename(pb, hyg) else null,
                .condition = try self.substExpr(s.condition, env, hyg),
                .then_block = try self.substBlock(s.then_block, env, hyg),
                .else_block = if (s.else_block) |eb| try self.substBlock(eb, env, hyg) else null,
                .span = s.span,
            } }),
            .while_stmt => |s| try out.append(self.arena, .{ .while_stmt = .{
                .condition = try self.substExpr(s.condition, env, hyg),
                .payload_binding = s.payload_binding,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .match_stmt => |s| {
                var arms: std.ArrayList(ast.MatchArm) = .empty;
                for (s.arms) |arm| {
                    const pat: ast.MatchPattern = switch (arm.pattern) {
                        .int_values => |vals| blk: {
                            var nv: std.ArrayList(ast.Expr) = .empty;
                            for (vals) |e| try nv.append(self.arena, try self.substExpr(e, env, hyg));
                            break :blk .{ .int_values = try nv.toOwnedSlice(self.arena) };
                        },
                        .range => |r| .{ .range = .{
                            .lo = try self.substExpr(r.lo, env, hyg),
                            .hi = try self.substExpr(r.hi, env, hyg),
                            .inclusive = r.inclusive,
                        } },
                        .binding => |name| .{ .binding = self.rename(name, hyg) },
                        else => arm.pattern,
                    };
                    try arms.append(self.arena, .{
                        .pattern = pat,
                        .binding = if (arm.binding) |b| self.rename(b, hyg) else null,
                        .guard = if (arm.guard) |g| try self.substExpr(g, env, hyg) else null,
                        .body = try self.substBlock(arm.body, env, hyg),
                        .span = arm.span,
                    });
                }
                try out.append(self.arena, .{ .match_stmt = .{ .subject = try self.substExpr(s.subject, env, hyg), .arms = try arms.toOwnedSlice(self.arena), .span = s.span } });
            },
            .for_range => |s| try out.append(self.arena, .{ .for_range = .{
                .binding = self.rename(s.binding, hyg),
                .start = try self.substExpr(s.start, env, hyg),
                .end = try self.substExpr(s.end, env, hyg),
                .inclusive = s.inclusive,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .for_slice => |s| try out.append(self.arena, .{ .for_slice = .{
                .binding = self.rename(s.binding, hyg),
                .index_binding = if (s.index_binding) |ib| self.rename(ib, hyg) else null,
                .by_ref = s.by_ref,
                .iter = try self.substExpr(s.iter, env, hyg),
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .zone_block => |s| try out.append(self.arena, .{ .zone_block = .{
                .name = self.rename(s.name, hyg),
                .kind = s.kind,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .defer_stmt => |s| try out.append(self.arena, .{ .defer_stmt = .{
                .mode = s.mode,
                .body = try self.substBlock(s.body, env, hyg),
                .span = s.span,
            } }),
            .unsafe_block => |b| try out.append(self.arena, .{ .unsafe_block = try self.substBlock(b, env, hyg) }),
            .comptime_run => |b| try out.append(self.arena, .{ .comptime_run = try self.substBlock(b, env, hyg) }),
            .comptime_if => |s| try out.append(self.arena, .{ .comptime_if = .{
                .condition = try self.substExpr(s.condition, env, hyg),
                .then_block = try self.substBlock(s.then_block, env, hyg),
                .else_block = if (s.else_block) |eb| try self.substBlock(eb, env, hyg) else null,
                .span = s.span,
            } }),
            .insert_stmt => |s| try out.append(self.arena, .{ .insert_stmt = .{ .operand = try self.substExpr(s.operand, env, hyg), .span = s.span } }),
            .break_stmt, .continue_stmt => try out.append(self.arena, stmt),
            .expr => |e| try out.append(self.arena, .{ .expr = try self.substExpr(e, env, hyg) }),
            // `#for` inside a macro template: unroll using the current env (so
            // bounds may reference macro params) plus the loop binding.
            .comptime_for => |cf| try self.unrollFor(cf, env, hyg, out),
        }
    }

    // #for unrolling

    /// Emit `cf.body` once per index in `[start, end)` (or `..=`), binding the
    /// loop variable to that index's literal so `$(i)` splices it.
    fn unrollFor(self: *Expander, cf: ast.ComptimeForStmt, env: *Env, base_hyg: *Hyg, out: *std.ArrayList(ast.Stmt)) ExpandError!void {
        const start = try self.evalIntBound(cf.start, env, base_hyg);
        const last = try self.evalIntBound(cf.end, env, base_hyg);
        const end = if (cf.inclusive) last + 1 else last;

        var i = start;
        while (i < end) : (i += 1) {
            const lit = try self.intLit(i, cf.start.id, cf.span);
            try env.put(cf.binding, lit);
            // Fresh hygiene per iteration so the body's own locals don't collide
            // across unrolled copies (start from the macro's renames, if any).
            var hyg = try self.cloneHyg(base_hyg);
            try self.collectIntroduced(cf.body, &hyg);
            const expanded = try self.substBlock(cf.body, env, &hyg);
            for (expanded.statements) |s| try out.append(self.arena, s);
        }
        _ = env.remove(cf.binding);
    }

    fn evalIntBound(self: *Expander, expr: ast.Expr, env: *Env, hyg: *Hyg) ExpandError!i64 {
        const e = try self.substExpr(expr, env, hyg);
        return intValue(e) orelse fail("#for bounds must be integer literals (or comptime parameters bound to literals)", .{});
    }

    fn intLit(self: *Expander, value: i64, id: ast.NodeId, span: Span) ExpandError!ast.Expr {
        const text = try std.fmt.allocPrint(self.arena, "{d}", .{value});
        return .{ .id = id, .kind = .{ .int = text }, .span = span };
    }

    fn cloneHyg(self: *Expander, base: *Hyg) ExpandError!Hyg {
        var h = Hyg.init(self.arena);
        var it = base.iterator();
        while (it.next()) |entry| try h.put(entry.key_ptr.*, entry.value_ptr.*);
        return h;
    }

    fn substExpr(self: *Expander, expr: ast.Expr, env: *Env, hyg: *Hyg) ExpandError!ast.Expr {
        switch (expr.kind) {
            .splice => |inner| {
                if (inner.kind != .ident) return fail("`$` splice must reference a macro parameter", .{});
                const name = inner.kind.ident;
                const arg = env.get(name) orelse return fail("`${s}` does not name a macro parameter", .{name});
                return switch (arg.kind) {
                    .quote_expr => |e| e.*,
                    .quote => fail("block argument `${s}` cannot be spliced in expression position", .{name}),
                    else => arg,
                };
            },
            .ident => |name| {
                if (hyg.get(name)) |fresh| {
                    return .{ .id = expr.id, .kind = .{ .ident = fresh }, .span = expr.span };
                }
                return expr;
            },
            .binary => |b| return self.rebuild(expr, .{ .binary = .{
                .op = b.op,
                .left = try self.substPtr(b.left, env, hyg),
                .right = try self.substPtr(b.right, env, hyg),
            } }),
            .unary => |u| return self.rebuild(expr, .{ .unary = .{
                .op = u.op,
                .expr = try self.substPtr(u.expr, env, hyg),
            } }),
            .call => |c| {
                var args: std.ArrayList(ast.CallArg) = .empty;
                for (c.args) |a| switch (a) {
                    .positional => |e| try args.append(self.arena, .{ .positional = try self.substExpr(e, env, hyg) }),
                    .named => |n| try args.append(self.arena, .{ .named = .{ .name = n.name, .value = try self.substExpr(n.value, env, hyg) } }),
                };
                return self.rebuild(expr, .{ .call = .{
                    .callee = try self.substPtr(c.callee, env, hyg),
                    .args = try args.toOwnedSlice(self.arena),
                } });
            },
            .field => |f| return self.rebuild(expr, .{ .field = .{
                .base = try self.substPtr(f.base, env, hyg),
                .name = f.name,
            } }),
            .index => |i| return self.rebuild(expr, .{ .index = .{
                .base = try self.substPtr(i.base, env, hyg),
                .index = try self.substPtr(i.index, env, hyg),
            } }),
            .as_cast => |c| return self.rebuild(expr, .{ .as_cast = .{
                .value = try self.substPtr(c.value, env, hyg),
                .to = c.to,
            } }),
            .nil_coalesce => |nc| return self.rebuild(expr, .{ .nil_coalesce = .{
                .value = try self.substPtr(nc.value, env, hyg),
                .default = try self.substPtr(nc.default, env, hyg),
            } }),
            .force_unwrap => |inner| return self.rebuild(expr, .{ .force_unwrap = try self.substPtr(inner, env, hyg) }),
            .run_expr => |inner| return self.rebuild(expr, .{ .run_expr = try self.substPtr(inner, env, hyg) }),
            .unsafe_expr => |inner| return self.rebuild(expr, .{ .unsafe_expr = try self.substPtr(inner, env, hyg) }),
            .compound_literal => |vals| {
                var nv: std.ArrayList(ast.Expr) = .empty;
                for (vals) |e| try nv.append(self.arena, try self.substExpr(e, env, hyg));
                return self.rebuild(expr, .{ .compound_literal = try nv.toOwnedSlice(self.arena) });
            },
            .slice => |s| return self.rebuild(expr, .{ .slice = .{
                .base = try self.substPtr(s.base, env, hyg),
                .start = if (s.start) |st| try self.substPtr(st, env, hyg) else null,
                .end = if (s.end) |en| try self.substPtr(en, env, hyg) else null,
            } }),
            .scope_access => |sa| return self.rebuild(expr, .{ .scope_access = .{
                .base = try self.substPtr(sa.base, env, hyg),
                .member = sa.member,
            } }),
            .try_expr => |t| return self.rebuild(expr, .{ .try_expr = .{ .value = try self.substPtr(t.value, env, hyg) } }),
            .catch_expr => |c| return self.rebuild(expr, .{ .catch_expr = .{
                .value = try self.substPtr(c.value, env, hyg),
                .err_name = c.err_name,
                .handler = try self.substBlock(c.handler, env, hyg),
            } }),
            .parse_expr => |inner| return self.rebuild(expr, .{ .parse_expr = try self.substPtr(inner, env, hyg) }),
            // Leaves (literals, type refs) and nested `#quote`s (kept as data)
            // substitute to themselves.
            else => return expr,
        }
    }

    fn substPtr(self: *Expander, p: *const ast.Expr, env: *Env, hyg: *Hyg) ExpandError!*const ast.Expr {
        return self.dup(try self.substExpr(p.*, env, hyg));
    }

    /// Substitute `$T` in type position. `$T` parses to a `.type_param`; if it
    /// names a macro parameter, splice that argument (interpreted as a type).
    /// Recurses into `*T` / `[]T` / `?T` so e.g. `*$T` works.
    fn substType(self: *Expander, ty: ast.TypeRef, env: *Env) ExpandError!ast.TypeRef {
        return switch (ty) {
            .type_param => |tp| if (env.get(tp.name)) |arg|
                (exprToTypeRef(arg) orelse fail("macro parameter `${s}` cannot be used as a type", .{tp.name}))
            else
                ty,
            .pointer => |p| .{ .pointer = .{ .is_const = p.is_const, .is_volatile = p.is_volatile, .inner = try self.dupType(try self.substType(p.inner.*, env)), .span = p.span } },
            .many_pointer => |p| .{ .many_pointer = .{ .is_const = p.is_const, .is_volatile = p.is_volatile, .inner = try self.dupType(try self.substType(p.inner.*, env)), .span = p.span } },
            .slice => |s| .{ .slice = .{ .is_const = s.is_const, .inner = try self.dupType(try self.substType(s.inner.*, env)), .span = s.span } },
            .optional => |o| .{ .optional = .{ .inner = try self.dupType(try self.substType(o.inner.*, env)), .span = o.span } },
            else => ty,
        };
    }

    fn dupType(self: *Expander, ty: ast.TypeRef) ExpandError!*const ast.TypeRef {
        const p = try self.arena.create(ast.TypeRef);
        p.* = ty;
        return p;
    }

    fn rebuild(self: *Expander, original: ast.Expr, kind: ast.ExprKind) ast.Expr {
        _ = self;
        return .{ .id = original.id, .kind = kind, .span = original.span };
    }

    fn rename(self: *Expander, name: []const u8, hyg: *Hyg) []const u8 {
        _ = self;
        return hyg.get(name) orelse name;
    }
};

/// A macro argument used in type position (`x: $t = …`) — convert the argument
/// expr to a type. Bare type names parse as `.type_ref`; identifiers to `.named`.
fn exprToTypeRef(e: ast.Expr) ?ast.TypeRef {
    return switch (e.kind) {
        .type_ref => |tr| tr,
        .ident => |name| .{ .named = .{ .name = name, .span = e.span } },
        else => null,
    };
}

/// Integer value of a literal expression (`5`, `-3`), or null if not a literal.
fn intValue(e: ast.Expr) ?i64 {
    return switch (e.kind) {
        .int => |t| std.fmt.parseInt(i64, t, 0) catch null,
        .unary => |u| if (u.op == .neg) blk: {
            const v = intValue(u.expr.*) orelse break :blk null;
            break :blk -v;
        } else null,
        else => null,
    };
}

/// Expand all macros in `module`, returning a macro-free module.
pub fn expand(arena: std.mem.Allocator, module: ast.Module) ExpandError!ast.Module {
    var expander = Expander{ .arena = arena, .macros = std.StringHashMap(ast.FunctionDecl).init(arena) };
    return expander.expandModule(module);
}
