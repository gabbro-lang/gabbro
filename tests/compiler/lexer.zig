const std = @import("std");
const skarn = @import("skarn_compiler");

test "skarn mod import test" {
    try std.testing.expect(@hasDecl(skarn, "TokenKind"));
}
