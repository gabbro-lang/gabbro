//! skarn language server — `skarn lsp`.
//!
//! A minimal LSP server over stdio (JSON-RPC). It is a *thin* layer over the
//! compiler frontend: every request is answered from a per-document analysis
//! produced by `parser.parseModule` + `sema.collectSymbols` +
//! `sema.checkTypesTolerant` (the tolerant checker, which returns a partial
//! result even on broken code — exactly what a live editor needs).
//!
//! stdout carries only LSP messages; all frontend diagnostics are captured as
//! data (never printed), so the protocol stays clean.
//!
//! Implemented: diagnostics, completion (scope symbols + keywords), hover,
//! go-to-definition, and document symbols. Member completion, references, and
//! rename are future work.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const ast = @import("ast.zig");
const diag = @import("diagnostic.zig");
const Span = @import("lexer/span.zig").Span;

const json = std.json;

// Per-document analysis

const Doc = struct {
    arena: std.heap.ArenaAllocator,
    uri: []u8, // owned by gpa
    text: []u8, // owned by gpa (stable across an analysis)
    /// Symbols for completion / definition / hover. Null if parsing failed.
    symbols: ?sema.SymbolTable = null,
    module: ?ast.Module = null,
    /// Combined parse + type diagnostics, owned by `arena`.
    diags: []const diag.Diagnostic = &.{},

    fn deinit(self: *Doc, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.free(self.uri);
        gpa.free(self.text);
    }
};

const Server = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    docs: std.StringHashMapUnmanaged(*Doc) = .{},
    shutdown_requested: bool = false,

    fn analyze(doc: *Doc) void {
        // Reset any previous analysis.
        _ = doc.arena.reset(.retain_capacity);
        doc.symbols = null;
        doc.module = null;
        doc.diags = &.{};
        const a = doc.arena.allocator();

        var p = parser.Parser.init(a, doc.uri, doc.text, 1) catch return;
        const module = p.parseModule() catch {
            // Syntax error — surface the parse diagnostics, skip type checking.
            doc.diags = a.dupe(diag.Diagnostic, p.diagnostics.items) catch &.{};
            return;
        };
        doc.module = module;

        var symbols = sema.collectSymbols(a, module) catch {
            doc.diags = a.dupe(diag.Diagnostic, p.diagnostics.items) catch &.{};
            return;
        };
        const types = sema.checkTypesTolerant(a, module, &symbols, doc.text, doc.uri) catch {
            doc.symbols = symbols;
            return;
        };
        doc.symbols = symbols;

        // Combine parse diagnostics (warnings) with the type diagnostics.
        var all = std.ArrayList(diag.Diagnostic).empty;
        all.appendSlice(a, p.diagnostics.items) catch {};
        all.appendSlice(a, types.diagnostics.items) catch {};
        doc.diags = all.toOwnedSlice(a) catch types.diagnostics.items;
    }

    fn upsert(self: *Server, uri: []const u8, text: []const u8) void {
        if (self.docs.get(uri)) |doc| {
            self.gpa.free(doc.text);
            doc.text = self.gpa.dupe(u8, text) catch return;
            analyze(doc);
            publishDiagnostics(self, doc);
            return;
        }
        const doc = self.gpa.create(Doc) catch return;
        doc.* = .{
            .arena = std.heap.ArenaAllocator.init(self.gpa),
            .uri = self.gpa.dupe(u8, uri) catch return,
            .text = self.gpa.dupe(u8, text) catch return,
        };
        self.docs.put(self.gpa, doc.uri, doc) catch return;
        analyze(doc);
        publishDiagnostics(self, doc);
    }

    fn close(self: *Server, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| {
            kv.value.deinit(self.gpa);
            self.gpa.destroy(kv.value);
        }
    }
};

// Position mapping (byte offset ↔ LSP UTF-16 position)

const Pos = struct { line: u32, char: u32 };

fn byteToPos(text: []const u8, offset: usize) Pos {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    const end = @min(offset, text.len);
    while (i < end) {
        const c = text[i];
        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        const seq = std.unicode.utf8ByteSequenceLength(c) catch {
            col += 1;
            i += 1;
            continue;
        };
        if (i + seq <= text.len) {
            const cp = std.unicode.utf8Decode(text[i .. i + seq]) catch {
                col += 1;
                i += 1;
                continue;
            };
            col += if (cp >= 0x10000) @as(u32, 2) else 1; // surrogate pair = 2 UTF-16 units
            i += seq;
        } else {
            col += 1;
            i += 1;
        }
    }
    return .{ .line = line, .char = col };
}

fn posToByte(text: []const u8, line: u32, character: u32) usize {
    var i: usize = 0;
    var ln: u32 = 0;
    while (i < text.len and ln < line) : (i += 1) {
        if (text[i] == '\n') ln += 1;
    }
    var c: u32 = 0;
    while (i < text.len and c < character and text[i] != '\n') {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            c += 1;
            i += 1;
            continue;
        };
        const cp = if (i + seq <= text.len) (std.unicode.utf8Decode(text[i .. i + seq]) catch 0) else 0;
        c += if (cp >= 0x10000) @as(u32, 2) else 1;
        i += seq;
    }
    return i;
}

fn isIdentChar(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// The identifier surrounding byte `offset`, or empty.
fn identAt(text: []const u8, offset: usize) []const u8 {
    if (text.len == 0) return "";
    var start = @min(offset, text.len);
    while (start > 0 and isIdentChar(text[start - 1])) start -= 1;
    var end = @min(offset, text.len);
    while (end < text.len and isIdentChar(text[end])) end += 1;
    if (end <= start) return "";
    return text[start..end];
}

// JSON output helpers

fn escapeInto(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => list.appendSlice(gpa, "\\\"") catch {},
        '\\' => list.appendSlice(gpa, "\\\\") catch {},
        '\n' => list.appendSlice(gpa, "\\n") catch {},
        '\r' => list.appendSlice(gpa, "\\r") catch {},
        '\t' => list.appendSlice(gpa, "\\t") catch {},
        else => if (c < 0x20) {
            list.print(gpa, "\\u{x:0>4}", .{c}) catch {};
        } else list.append(gpa, c) catch {},
    };
}

/// Re-serialize a JSON-RPC id (int or string) for echoing in a response.
fn idToBuf(list: *std.ArrayList(u8), gpa: std.mem.Allocator, id: ?json.Value) void {
    if (id) |v| switch (v) {
        .integer => |n| list.print(gpa, "{d}", .{n}) catch {},
        .string => |s| {
            list.append(gpa, '"') catch {};
            escapeInto(list, gpa, s);
            list.append(gpa, '"') catch {};
        },
        else => list.appendSlice(gpa, "null") catch {},
    } else list.appendSlice(gpa, "null") catch {};
}

fn send(self: *Server, body: []const u8) void {
    self.out.print("Content-Length: {d}\r\n\r\n", .{body.len}) catch {};
    self.out.writeAll(body) catch {};
    self.out.flush() catch {};
}

fn sendResult(self: *Server, id: ?json.Value, result_json: []const u8) void {
    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":") catch {};
    idToBuf(&b, self.gpa, id);
    b.appendSlice(self.gpa, ",\"result\":") catch {};
    b.appendSlice(self.gpa, result_json) catch {};
    b.append(self.gpa, '}') catch {};
    send(self, b.items);
}

// JSON input helpers

fn objGet(v: json.Value, key: []const u8) ?json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}
fn getStr(v: json.Value, key: []const u8) ?[]const u8 {
    const f = objGet(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}
fn getInt(v: json.Value, key: []const u8) ?i64 {
    const f = objGet(v, key) orelse return null;
    return switch (f) {
        .integer => |n| n,
        else => null,
    };
}

// Kind mappings

fn completionKind(k: sema.SymbolKind) u8 {
    return switch (k) {
        .function => 3, // Function
        .type => 7, // Class
        .const_symbol => 21, // Constant
        .param, .local_val, .local_var, .local_const, .global_var => 6, // Variable
        .field => 5, // Field
        .variant => 20, // EnumMember
        else => 6,
    };
}

fn symbolKind(k: sema.SymbolKind) u8 {
    return switch (k) {
        .function => 12, // Function
        .type => 23, // Struct
        .const_symbol => 14, // Constant
        .field => 8, // Field
        .variant => 22, // EnumMember
        else => 13, // Variable
    };
}

const keywords = [_][]const u8{
    "fn",   "struct",  "enum",  "errors", "interface", "if",     "else",  "while", "for",
    "in",   "return",  "match", "pub",    "const",     "unsafe", "defer", "zone",  "catch",
    "fail", "true",    "false", "null",   "as",        "i8",     "i16",   "i32",   "i64",
    "u8",   "u16",     "u32",   "u64",    "usize",     "isize",  "bool",  "f32",   "f64",
    "void", "byte",
};

// Request handlers

fn handleInitialize(self: *Server, id: ?json.Value) void {
    sendResult(self, id,
        \\{"capabilities":{"textDocumentSync":1,"completionProvider":{"triggerCharacters":[".",":"]},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true},"serverInfo":{"name":"skarn-lsp","version":"0.1.0"}}
    );
}

fn publishDiagnostics(self: *Server, doc: *Doc) void {
    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"") catch {};
    escapeInto(&b, self.gpa, doc.uri);
    b.appendSlice(self.gpa, "\",\"diagnostics\":[") catch {};
    var first = true;
    for (doc.diags) |d| {
        // Only diagnostics that belong to this file (imports may add others).
        if (!std.mem.eql(u8, d.file, doc.uri)) continue;
        const s = byteToPos(doc.text, d.span.start);
        const e = byteToPos(doc.text, d.span.end);
        if (!first) b.append(self.gpa, ',') catch {};
        first = false;
        const severity: u8 = switch (d.kind) {
            .err => 1,
            .warning => 2,
            .note => 3,
            else => 1,
        };
        b.print(self.gpa, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"skarn\",\"message\":\"", .{ s.line, s.char, e.line, e.char, severity }) catch {};
        escapeInto(&b, self.gpa, d.message);
        b.appendSlice(self.gpa, "\"}") catch {};
    }
    b.appendSlice(self.gpa, "]}}") catch {};
    send(self, b.items);
}

fn handleCompletion(self: *Server, id: ?json.Value, params: json.Value) void {
    const td = objGet(params, "textDocument") orelse return sendResult(self, id, "null");
    const uri = getStr(td, "uri") orelse return sendResult(self, id, "null");
    const doc = self.docs.get(uri) orelse return sendResult(self, id, "null");

    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.append(self.gpa, '[') catch {};
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(self.gpa);
    var first = true;

    if (doc.symbols) |syms| {
        for (syms.symbols.items) |sym| {
            switch (sym.kind) {
                .function, .type, .const_symbol => {},
                else => continue,
            }
            if (sym.name.len == 0 or sym.name[0] == '_') continue;
            // Skip hoisted method names like "Vec.push" (offered via member completion later).
            if (std.mem.indexOfScalar(u8, sym.name, '.') != null) continue;
            if (seen.contains(sym.name)) continue;
            seen.put(self.gpa, sym.name, {}) catch {};
            if (!first) b.append(self.gpa, ',') catch {};
            first = false;
            b.appendSlice(self.gpa, "{\"label\":\"") catch {};
            escapeInto(&b, self.gpa, sym.name);
            b.print(self.gpa, "\",\"kind\":{d}}}", .{completionKind(sym.kind)}) catch {};
        }
    }
    for (keywords) |kw| {
        if (seen.contains(kw)) continue;
        if (!first) b.append(self.gpa, ',') catch {};
        first = false;
        b.appendSlice(self.gpa, "{\"label\":\"") catch {};
        escapeInto(&b, self.gpa, kw);
        b.appendSlice(self.gpa, "\",\"kind\":14}") catch {}; // Keyword
    }
    b.append(self.gpa, ']') catch {};
    sendResult(self, id, b.items);
}

/// Find the symbol whose name matches the identifier under the cursor.
fn symbolUnderCursor(doc: *Doc, params: json.Value) ?sema.Symbol {
    const syms = doc.symbols orelse return null;
    const position = objGet(params, "position") orelse return null;
    const line: u32 = @intCast(getInt(position, "line") orelse return null);
    const character: u32 = @intCast(getInt(position, "character") orelse return null);
    const off = posToByte(doc.text, line, character);
    const word = identAt(doc.text, off);
    if (word.len == 0) return null;
    // Prefer a top-level/visible symbol; fall back to any symbol with that name.
    if (syms.resolveVisible(doc.uri, word)) |sid| return syms.symbol(sid);
    for (syms.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, word)) return sym;
    }
    return null;
}

fn handleDefinition(self: *Server, id: ?json.Value, params: json.Value) void {
    const td = objGet(params, "textDocument") orelse return sendResult(self, id, "null");
    const uri = getStr(td, "uri") orelse return sendResult(self, id, "null");
    const doc = self.docs.get(uri) orelse return sendResult(self, id, "null");
    const sym = symbolUnderCursor(doc, params) orelse return sendResult(self, id, "null");
    // Only resolve definitions that live in this same document (single-file v1).
    if (!std.mem.eql(u8, sym.file_name, doc.uri)) return sendResult(self, id, "null");

    const s = byteToPos(doc.text, sym.span.start);
    const e = byteToPos(doc.text, sym.span.end);
    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.appendSlice(self.gpa, "{\"uri\":\"") catch {};
    escapeInto(&b, self.gpa, doc.uri);
    b.print(self.gpa, "\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ s.line, s.char, e.line, e.char }) catch {};
    sendResult(self, id, b.items);
}

fn handleHover(self: *Server, id: ?json.Value, params: json.Value) void {
    const td = objGet(params, "textDocument") orelse return sendResult(self, id, "null");
    const uri = getStr(td, "uri") orelse return sendResult(self, id, "null");
    const doc = self.docs.get(uri) orelse return sendResult(self, id, "null");
    const sym = symbolUnderCursor(doc, params) orelse return sendResult(self, id, "null");

    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.appendSlice(self.gpa, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"```skarn\\n") catch {};
    escapeInto(&b, self.gpa, sym.kind.label());
    b.appendSlice(self.gpa, " ") catch {};
    escapeInto(&b, self.gpa, sym.name);
    b.appendSlice(self.gpa, "\\n```\"}}") catch {};
    sendResult(self, id, b.items);
}

fn handleDocumentSymbol(self: *Server, id: ?json.Value, params: json.Value) void {
    const td = objGet(params, "textDocument") orelse return sendResult(self, id, "null");
    const uri = getStr(td, "uri") orelse return sendResult(self, id, "null");
    const doc = self.docs.get(uri) orelse return sendResult(self, id, "null");

    var b = std.ArrayList(u8).empty;
    defer b.deinit(self.gpa);
    b.append(self.gpa, '[') catch {};
    var first = true;
    if (doc.symbols) |syms| {
        for (syms.symbols.items) |sym| {
            switch (sym.kind) {
                .function, .type, .const_symbol => {},
                else => continue,
            }
            if (!std.mem.eql(u8, sym.file_name, doc.uri)) continue;
            if (std.mem.indexOfScalar(u8, sym.name, '.') != null) continue; // hoisted methods
            const s = byteToPos(doc.text, sym.span.start);
            const e = byteToPos(doc.text, sym.span.end);
            if (!first) b.append(self.gpa, ',') catch {};
            first = false;
            b.appendSlice(self.gpa, "{\"name\":\"") catch {};
            escapeInto(&b, self.gpa, sym.name);
            b.print(self.gpa, "\",\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ symbolKind(sym.kind), s.line, s.char, e.line, e.char, s.line, s.char, e.line, e.char }) catch {};
        }
    }
    b.append(self.gpa, ']') catch {};
    sendResult(self, id, b.items);
}

fn dispatch(self: *Server, root: json.Value) void {
    const method = getStr(root, "method") orelse return;
    const id = objGet(root, "id");
    const params = objGet(root, "params") orelse json.Value{ .null = {} };

    if (std.mem.eql(u8, method, "initialize")) {
        handleInitialize(self, id);
    } else if (std.mem.eql(u8, method, "initialized")) {
        // notification, no-op
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const td = objGet(params, "textDocument") orelse return;
        const uri = getStr(td, "uri") orelse return;
        const text = getStr(td, "text") orelse return;
        self.upsert(uri, text);
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        const td = objGet(params, "textDocument") orelse return;
        const uri = getStr(td, "uri") orelse return;
        const changes = objGet(params, "contentChanges") orelse return;
        // Full-sync: the last change carries the whole document.
        switch (changes) {
            .array => |arr| {
                if (arr.items.len == 0) return;
                const last = arr.items[arr.items.len - 1];
                const text = getStr(last, "text") orelse return;
                self.upsert(uri, text);
            },
            else => {},
        }
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        const td = objGet(params, "textDocument") orelse return;
        const uri = getStr(td, "uri") orelse return;
        self.close(uri);
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        handleCompletion(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
        handleHover(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/definition")) {
        handleDefinition(self, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        handleDocumentSymbol(self, id, params);
    } else if (std.mem.eql(u8, method, "shutdown")) {
        self.shutdown_requested = true;
        sendResult(self, id, "null");
    } else if (std.mem.eql(u8, method, "exit")) {
        self.shutdown_requested = true;
    } else if (id != null) {
        // Unknown request — reply null so the client isn't left waiting.
        sendResult(self, id, "null");
    }
}

// The stdio loop

pub fn run(gpa: std.mem.Allocator, io: std.Io) u8 {
    var in_buf: [1 << 16]u8 = undefined;
    var out_buf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &in_buf);
    var writer = std.Io.File.stdout().writer(io, &out_buf);

    var server = Server{ .gpa = gpa, .out = &writer.interface };
    defer {
        var it = server.docs.valueIterator();
        while (it.next()) |d| {
            d.*.deinit(gpa);
            gpa.destroy(d.*);
        }
        server.docs.deinit(gpa);
    }

    while (!server.shutdown_requested) {
        // Read headers: lines until a blank line, extracting Content-Length.
        var content_len: usize = 0;
        var got_header = false;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return 0; // EOF → exit
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break; // end of headers
            got_header = true;
            const prefix = "Content-Length:";
            if (std.ascii.startsWithIgnoreCase(trimmed, prefix)) {
                const num = std.mem.trim(u8, trimmed[prefix.len..], " ");
                content_len = std.fmt.parseInt(usize, num, 10) catch 0;
            }
        }
        if (!got_header or content_len == 0) continue;

        const body = reader.interface.readAlloc(gpa, content_len) catch return 0;
        defer gpa.free(body);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), body, .{}) catch continue;
        dispatch(&server, root);
    }
    return 0;
}

// Tests

test "lsp: byte offset ↔ UTF-16 position round-trips, incl. multibyte" {
    const t = std.testing;
    const src = "ab\ncдe\nx"; // 'д' is 2 UTF-8 bytes, 1 UTF-16 unit
    // line 0
    try t.expectEqual(Pos{ .line = 0, .char = 0 }, byteToPos(src, 0));
    try t.expectEqual(Pos{ .line = 0, .char = 2 }, byteToPos(src, 2));
    // line 1: 'c'(1) 'д'(2 bytes) 'e' — byte offset of 'e' is start+1+2 = 4..
    const line1_start = std.mem.indexOfScalar(u8, src, '\n').? + 1;
    // 'e' sits one UTF-16 unit past 'д' (which is one unit past 'c')
    const e_byte = line1_start + 1 + 2;
    try t.expectEqual(Pos{ .line = 1, .char = 2 }, byteToPos(src, e_byte));
    // round-trip back
    try t.expectEqual(e_byte, posToByte(src, 1, 2));
    try t.expectEqual(@as(usize, 2), posToByte(src, 0, 2));
}

test "lsp: identifier under a byte offset" {
    const t = std.testing;
    const src = "foo bar_baz + qux";
    try t.expectEqualStrings("foo", identAt(src, 1));
    try t.expectEqualStrings("bar_baz", identAt(src, 6));
    try t.expectEqualStrings("qux", identAt(src, 17)); // end of buffer
    try t.expectEqualStrings("", identAt(src, 12)); // on the '+'
}
