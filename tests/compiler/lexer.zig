const std = @import("std");
const k2 = @import("k2_compiler");

test "k2 mod import test" {
    try std.testing.expect(@hasDecl(k2, "TokenKind"));
}
