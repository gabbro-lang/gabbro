# C interop: by-value structs

Demonstrates calling a C library from Gabbro with structs passed/returned **by
value** — the calling pattern raylib (and most C UI/graphics libraries) use for
`Vector2`, `Color`, `Rectangle`, and friends.

Gabbro applies the Win64 C ABI at the `#extern` boundary automatically:

| C type      | size | how it crosses the boundary        |
|-------------|------|------------------------------------|
| `Color`     | 4 B  | coerced to an `i32` register       |
| `Vector2`   | 8 B  | coerced to an `i64` register       |
| `Rectangle` | 16 B | passed by pointer (`byval` / `sret`) |

You declare the struct on the Gabbro side to match the C layout; the compiler does
the register/coercion/indirection bookkeeping.

## Build & run

```sh
# 1. Build the C side the way any C dependency is built.
clang -c -target x86_64-pc-windows-msvc -O2 cabi.c -o cabi.obj
llvm-lib /out:cabi.lib cabi.obj

# 2. Build the Gabbro program. The `#extern("cabi", ...)` decls pull in cabi.lib;
#    --lib-path tells the linker where to find it.
gabbro build main.gab -o demo.exe --lib-path .

# 3. Run it — the exit code is 132 if every struct crossed the ABI correctly.
./demo.exe ; echo $?
```

`132 = 7 + 100 + 10 + 11 + 4`, summing the round-trips through each struct shape.

For a real library you wouldn't hand-write the `#extern` block — generate it from
the C header with `gabbro bindgen cabi.h --lib cabi -o cabi.gab`, then `#import cabi.*;`.
See [docs/11_c_interop.md](../../docs/11_c_interop.md) for the full story.

> Linking a non-system import library currently routes through LLD (the
> self-hosted `gabld` doesn't read `.lib` archives yet), so this needs the LLVM
> toolchain's `lld-link` on the search path — which `gabbro` already configures.
