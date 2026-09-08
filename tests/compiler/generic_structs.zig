const std = @import("std");
const gabbro = @import("gabbro_compiler");

test "generic struct: declaration and basic instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Pair :: struct($T: type) {
        \\    first:  T,
        \\    second: T,
        \\}
        \\
        \\// Use with concrete types (common case)
        \\make_int_pair :: fn(a: i32, b: i32) -> Pair(i32) {
        \\    result: Pair(i32) = .{ a, b };
        \\    return result;
        \\}
        \\
        \\sum_pair :: fn(p: Pair(i32)) -> i32 {
        \\    return p.first + p.second;
        \\}
    ;
    var fe = try gabbro.compile(arena.allocator(), "pair.gab", src);
    defer fe.deinit(arena.allocator());
    const m = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(m);

    // The instantiated struct should appear in module.structs
    var found_pair_i32 = false;
    for (m.structs) |s| {
        if (std.mem.startsWith(u8, s.name, "Pair__")) {
            found_pair_i32 = true;
            try std.testing.expectEqual(@as(usize, 2), s.fields.len);
        }
    }
    try std.testing.expect(found_pair_i32);
}

test "generic struct: ArrayList-style container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\ArrayList :: struct($T: type) {
        \\    data: [*]T,
        \\    len:  usize,
        \\    cap:  usize,
        \\}
        \\
        \\al_len :: fn(list: *ArrayList(i32)) -> usize {
        \\    return list.len;
        \\}
        \\
        \\al_len_u8 :: fn(list: *ArrayList(u8)) -> usize {
        \\    return list.len;
        \\}
    ;
    var fe = try gabbro.compile(arena.allocator(), "list.gab", src);
    defer fe.deinit(arena.allocator());
    const m = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(m);

    // Two separate instantiations: ArrayList(i32) and ArrayList(u8)
    var count: usize = 0;
    for (m.structs) |s| {
        if (std.mem.startsWith(u8, s.name, "ArrayList__")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "generic struct: two type params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Map :: struct($K: type, $V: type) {
        \\    key:   K,
        \\    value: V,
        \\    valid: bool,
        \\}
        \\
        \\lookup :: fn(m: *Map([]const u8, i32)) -> i32 {
        \\    if m.valid { return m.value; }
        \\    return 0;
        \\}
    ;
    var fe = try gabbro.compile(arena.allocator(), "map.gab", src);
    defer fe.deinit(arena.allocator());
    const m = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(m);

    var found = false;
    for (m.structs) |s| {
        if (std.mem.startsWith(u8, s.name, "Map__")) {
            found = true;
            try std.testing.expectEqual(@as(usize, 3), s.fields.len);
        }
    }
    try std.testing.expect(found);
}

test "generic struct: same type used twice gives one instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Box :: struct($T: type) { value: T }
        \\
        \\a :: fn(b: *Box(i32)) -> i32 { return b.value; }
        \\c :: fn(b: *Box(i32)) -> i32 { return b.value + 1; }
    ;
    var fe = try gabbro.compile(arena.allocator(), "box.gab", src);
    defer fe.deinit(arena.allocator());
    const m = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(m);

    var count: usize = 0;
    for (m.structs) |s| {
        if (std.mem.startsWith(u8, s.name, "Box__")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
