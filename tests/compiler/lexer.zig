const std = @import("std");
const gabbro = @import("gabbro_compiler");

test "gabbro mod import test" {
    try std.testing.expect(@hasDecl(gabbro, "TokenKind"));
}
