//! Free-variable analysis for lambda bodies.
//!
//! A capturing closure needs to know which names a lambda body references that
//! are bound neither by its parameters nor by a local it declares — those are
//! the *free variables*, the candidates for capture. The caller (sema) then
//! resolves each in the lambda's definition scope and keeps only the ones that
//! are enclosing locals.
//!
//! This over-approximates with global/builtin names (harmless — they filter out)
//! but must never *under*-approximate a genuine reference, which would silently
//! drop a capture. So every sub-expression is walked; only name *bindings* use
//! lexical scoping (a name declared in a block is unbound again when it ends).

const std = @import("std");
const ast = @import("ast.zig");

/// Free variables of `body`, given the lambda's `params` are already bound.
/// Caller owns the returned slice.
pub fn analyze(
    allocator: std.mem.Allocator,
    params: []const ast.Param,
    body: ast.Block,
) ![]const []const u8 {
    var a = Analyzer{ .allocator = allocator };
    defer a.bound.deinit(allocator);
    errdefer a.free.deinit(allocator);
    for (params) |p| try a.bound.append(allocator, p.name);
    try a.walkBlock(body);
    return a.free.toOwnedSlice(allocator);
}

const Analyzer = struct {
    allocator: std.mem.Allocator,
    bound: std.ArrayList([]const u8) = .empty,
    free: std.ArrayList([]const u8) = .empty,

    fn isBound(self: *Analyzer, name: []const u8) bool {
        for (self.bound.items) |b| if (std.mem.eql(u8, b, name)) return true;
        return false;
    }

    fn ref(self: *Analyzer, name: []const u8) !void {
        if (std.mem.eql(u8, name, "_")) return;
        if (self.isBound(name)) return;
        for (self.free.items) |f| if (std.mem.eql(u8, f, name)) return;
        try self.free.append(self.allocator, name);
    }

    fn bind(self: *Analyzer, name: []const u8) !void {
        try self.bound.append(self.allocator, name);
    }

    fn walkBlock(self: *Analyzer, block: ast.Block) anyerror!void {
        const mark = self.bound.items.len;
        for (block.statements) |s| try self.walkStmt(s);
        self.bound.shrinkRetainingCapacity(mark);
    }

    fn walkStmt(self: *Analyzer, stmt: ast.Stmt) anyerror!void {
        switch (stmt) {
            .local_infer => |s| {
                try self.walkExpr(s.value);
                try self.bind(s.name);
            },
            .local_typed => |s| {
                try self.walkExpr(s.value);
                try self.bind(s.name);
            },
            .assign => |s| {
                try self.walkExpr(s.target);
                try self.walkExpr(s.value);
            },
            .return_stmt => |s| if (s.value) |v| try self.walkExpr(v),
            .fail_stmt => |s| for (s.payload) |p| try self.walkExpr(p),
            .expr => |e| try self.walkExpr(e),
            .if_stmt => |s| {
                try self.walkExpr(s.condition);
                if (s.binding) |b| try self.walkExpr(b.value);
                const mark = self.bound.items.len;
                if (s.binding) |b| try self.bind(b.name);
                if (s.payload_binding) |p| try self.bind(p);
                try self.walkBlock(s.then_block);
                self.bound.shrinkRetainingCapacity(mark);
                if (s.else_block) |e| try self.walkBlock(e);
            },
            .while_stmt => |s| {
                try self.walkExpr(s.condition);
                const mark = self.bound.items.len;
                if (s.payload_binding) |p| try self.bind(p);
                try self.walkBlock(s.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .for_range => |s| {
                try self.walkExpr(s.start);
                try self.walkExpr(s.end);
                const mark = self.bound.items.len;
                try self.bind(s.binding);
                try self.walkBlock(s.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .for_slice => |s| {
                try self.walkExpr(s.iter);
                const mark = self.bound.items.len;
                try self.bind(s.binding);
                if (s.index_binding) |ix| try self.bind(ix);
                try self.walkBlock(s.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .match_stmt => |s| {
                try self.walkExpr(s.subject);
                for (s.arms) |arm| {
                    const mark = self.bound.items.len;
                    if (arm.binding) |b| try self.bind(b);
                    if (arm.guard) |g| try self.walkExpr(g);
                    try self.walkBlock(arm.body);
                    self.bound.shrinkRetainingCapacity(mark);
                }
            },
            .zone_block => |s| {
                const mark = self.bound.items.len;
                try self.bind(s.name);
                try self.walkBlock(s.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .unsafe_block, .comptime_run => |b| try self.walkBlock(b),
            .defer_stmt => |s| try self.walkBlock(s.body),
            .comptime_if => |s| {
                try self.walkExpr(s.condition);
                try self.walkBlock(s.then_block);
                if (s.else_block) |e| try self.walkBlock(e);
            },
            .comptime_for => |s| {
                try self.walkExpr(s.start);
                try self.walkExpr(s.end);
                const mark = self.bound.items.len;
                try self.bind(s.binding);
                try self.walkBlock(s.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .insert_stmt => |s| try self.walkExpr(s.operand),
            .break_stmt, .continue_stmt => {},
        }
    }

    fn walkExpr(self: *Analyzer, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .ident => |name| try self.ref(name),
            .binary => |b| {
                try self.walkExpr(b.left.*);
                try self.walkExpr(b.right.*);
            },
            .unary => |u| try self.walkExpr(u.expr.*),
            .call => |c| {
                try self.walkExpr(c.callee.*);
                for (c.args) |a| switch (a) {
                    .positional => |x| try self.walkExpr(x),
                    .named => |n| try self.walkExpr(n.value),
                };
            },
            .field => |f| try self.walkExpr(f.base.*),
            .index => |i| {
                try self.walkExpr(i.base.*);
                try self.walkExpr(i.index.*);
            },
            .slice => |s| {
                try self.walkExpr(s.base.*);
                if (s.start) |x| try self.walkExpr(x.*);
                if (s.end) |x| try self.walkExpr(x.*);
            },
            .as_cast => |c| try self.walkExpr(c.value.*),
            .force_unwrap, .unsafe_expr, .run_expr, .quote_expr, .splice, .parse_expr => |inner| try self.walkExpr(inner.*),
            .nil_coalesce => |nc| {
                try self.walkExpr(nc.value.*);
                try self.walkExpr(nc.default.*);
            },
            .try_expr => |t| try self.walkExpr(t.value.*),
            .catch_expr => |c| {
                try self.walkExpr(c.value.*);
                const mark = self.bound.items.len;
                try self.bind(c.err_name);
                try self.walkBlock(c.handler);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .compound_literal => |fields| for (fields) |f| try self.walkExpr(f),
            .struct_literal => |fields| for (fields) |f| try self.walkExpr(f.value),
            .match_expr => |m| {
                try self.walkExpr(m.subject.*);
                for (m.arms) |arm| {
                    const mark = self.bound.items.len;
                    if (arm.binding) |b| try self.bind(b);
                    if (arm.guard) |g| try self.walkExpr(g);
                    try self.walkExpr(arm.value);
                    self.bound.shrinkRetainingCapacity(mark);
                }
            },
            .if_expr => |ie| {
                try self.walkExpr(ie.cond);
                try self.walkExpr(ie.then_value);
                try self.walkExpr(ie.else_value);
            },
            // `ns::member` — the base names a namespace, not a local; a quotation
            // is inert data. Neither contributes free variables.
            .scope_access, .quote, .type_ref, .int, .float, .string, .bool, .null => {},
        }
    }
};

test "free variables: a param and a body local are bound, an outer name is free" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `outer` is free; `x` (param) and `tmp` (local) are bound; `_` is ignored.
    const src =
        \\m :: fn() -> i32 { f := fn(x: i32) -> i32 { tmp := x + outer; _ := tmp; return tmp; }; return f(1); }
        \\
    ;
    var p = try parser.Parser.init(a, "fv.sk", src, 1);
    const module = try p.parseModule();
    // The lifted lambda is appended after `m`.
    var lambda: ?ast.FunctionDecl = null;
    for (module.items) |item| switch (item) {
        .function => |d| if (std.mem.startsWith(u8, d.name, "__lambda_")) {
            lambda = d;
        },
        else => {},
    };
    const lam = lambda orelse return error.NoLambda;
    const free = try analyze(a, lam.params, lam.body.?);
    try std.testing.expectEqual(@as(usize, 1), free.len);
    try std.testing.expectEqualStrings("outer", free[0]);
}
