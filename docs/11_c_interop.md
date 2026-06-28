# 11. C interoperability

Skarn talks to C libraries directly: declare the functions you need with `#extern`,
link the import library, and call them. Structs cross the boundary **by value**
with the correct platform ABI, and an automated generator turns C headers into
Skarn bindings so you don't hand-write hundreds of declarations.

## Declaring C functions

`#extern("<lib>", "<symbol>")` binds an external C function. The body is omitted
(it lives in the C library), and the `<lib>` is pulled into the link automatically.

```skarn
#extern("raylib", "InitWindow")
InitWindow :: fn(width: i32, height: i32, title: [*]const u8);

#extern("raylib", "WindowShouldClose")
WindowShouldClose :: fn() -> bool;
```

`#foreign(...)` is an alias for `#extern(...)`. `#system_library("name");` is a
standalone linking directive (no symbols introduced) for a library you depend on
but don't declare functions from directly.

`std.c` provides C-ABI type aliases (`c_int`, `c_long`, `c_size_t`, `c_string`, …)
sized for 64-bit Windows (LLP64), so signatures can read like their C originals.

## Passing structs by value (the raylib pattern)

C UI/graphics libraries pass small aggregates by value everywhere. Declare the
struct on the Skarn side to match the C layout and pass it directly — the compiler
applies the Win64 C ABI at the boundary:

```skarn
Color   :: struct { r: u8, g: u8, b: u8, a: u8 }   // 4 bytes
Vector2 :: struct { x: f32, y: f32 }               // 8 bytes
Rect    :: struct { x: f32, y: f32, w: f32, h: f32 } // 16 bytes

#extern("raylib", "DrawCircleV")
DrawCircleV :: fn(center: Vector2, radius: f32, color: Color);
```

| aggregate size | how it is passed/returned                  |
|----------------|--------------------------------------------|
| 1, 2, 4, 8 B   | coerced into an integer register           |
| any other size | by pointer (`byval` argument / `sret` return) |

This matches what a C compiler (clang/MSVC) does, so the bits arrive intact.
Floating-point *struct members* are not special-cased on Win64 (only naked
`float`/`double` scalar arguments use XMM), so `Vector2` correctly travels as a
64-bit integer. See `examples/c_interop/` for a runnable round-trip.

## Linking

The library named in `#extern`/`#system_library` is resolved at link time. Point
the linker at it:

- **CLI:** `skarn build app.sk -o app.exe --lib-path <dir> [--lib <name>]`
- **build.sk:** `app.link("raylib"); app.lib_path("vendor/raylib/lib");`

Linking a non-system import library currently routes through LLD (the self-hosted
`skarnld` doesn't read `.lib` archives yet); `skarn` configures `lld-link` for you.

### Linking the C runtime (`link_libc`)

Skarn links with `/NODEFAULTLIB` and its own tiny runtime — it does **not** pull in
the C runtime. That's fine for pure Skarn, but a C library brings its *code* and not
the CRT it depends on. A **static** library (e.g. a `raylib.lib` built against the
CRT) calls `malloc`/`free`/`calloc`/`realloc` and the compiler's stack/security
helpers (`__chkstk`, `__report_rangecheckfailure`), so linking it without the CRT
fails with `undefined symbol: malloc` and friends.

Link the C runtime to fix it:

- **CLI:** `skarn build app.sk --libc` (or `-lc`)
- **build.sk:** `app.link_libc();`

`link_libc` pulls in the UCRT (`ucrt.lib` — malloc/free/…) and the VC runtime
(`vcruntime.lib` — `__chkstk`, security checks). Both search paths are found for
you: the UCRT path is derived from the configured Windows SDK path, and the MSVC
`lib/x64` directory (where `vcruntime.lib` lives) is **auto-discovered** — `skarn`
scans the standard `…/Microsoft Visual Studio/<year>/<edition>/VC/Tools/MSVC/<ver>/lib/x64`
locations and uses the newest toolset it finds. So you normally don't configure
anything. If your toolchain is on a non-default drive, override the discovery by
building `skarn` with `-Dmsvc-lib-path=<…/VC/Tools/MSVC/<ver>/lib/x64>`, or pass
`--lib-path <that dir>` on the command line.

Skarn's own functions are **module-private** (internal linkage — the whole program is
one object), so they never clash with the CRT's `exit`/`abort`/etc. when you link
libc. A complete static-raylib build is just:

```sh
skarn build game.sk --libc --lib-path <raylib-lib-dir>
```

(or `app.link_libc()` in a build.sk — the MSVC path is discovered automatically).

> A static library also needs *its own* system dependencies. Static raylib, for
> example, also wants `gdi32`, `user32`, `winmm`, `shell32`, and `opengl32` —
> add them with `app.link("gdi32")` etc. The **DLL** distribution of a library
> avoids all of this (the `.dll` already contains its CRT and dependencies), so
> prefer it when available.

### Static vs dynamic — automatic

You don't rename or swap library files to switch link mode, and in the common case
you don't even say which mode you want. **The build peeks inside each `.lib` you
link** (in the artifact's own `lib_path`s *and* the directory containing
`build.sk`, so a `raylib.lib` sitting next to your build script is detected even
with no `lib_path` call) and reacts to what it finds:

- an **import library** (it carries an `__IMPORT_DESCRIPTOR_<dll>` symbol) → the
  build copies the matching `.dll` next to the output exe automatically, and
- a **static archive** → the build links the C runtime automatically.

So this is usually all you write:

```skarn
build :: fn(b: Build) {
    game := b.executable("game", "src/main.sk");
    game.link("raylib");
    game.lib_path("vendor/raylib/lib");   // whichever raylib.lib is here decides the mode
    b.default(game);
}
```

If `vendor/raylib/lib/raylib.lib` is the import library, you'll see
`raylib → dynamic (raylib.dll)` and the DLL lands next to the exe; if it's the
static archive, the C runtime is linked for you. The bindings (`#extern("raylib", …)`)
never change — only which `raylib.lib` is on the path.

#### Explicit overrides

The detection only covers the artifact's own libraries (not system libs), and you
can always be explicit:

- **`game.static_link()`** / **`game.link_mode(.static)`** — force linking the C
  runtime (e.g. if you also list the library's system deps yourself).
- **`game.dynamic()`** — force dynamic mode.
- **`game.runtime_file("…/extra.dll")`** — copy an extra DLL the detector can't infer.
- **`game.link_libc()`** — the low-level "link the C runtime" used by `static_link`.

#### System dependencies — pulled in automatically

A static C library also needs *its own* system deps (static raylib wants
`opengl32`/`gdi32`/…). You normally **don't list them** — when a static C library
is linked, Skarn honors that library's own embedded `/DEFAULTLIB` directives, exactly
like a C compiler does, so its system dependencies flow in automatically:

```skarn
build :: fn(b: Build) {
    game := b.executable("game", "src/main.sk");
    game.link("raylib");
    game.lib_path("vendor/raylib/lib-static");   // raylib.lib (static archive)
    b.default(game);                              // opengl32/gdi32/winmm pulled in for you
}
```

Skarn stays minimal-runtime by default: it links `/NODEFAULTLIB` and provides its own
tiny runtime, so a plain Skarn program pulls in nothing. The honoring kicks in **only**
when a static C library is involved — and even then Skarn suppresses just the CRT-startup
*umbrella* libs (`libcmt`/`msvcrt`/…), whose `mainCRTStartup` would clash with Skarn's
entry, while letting the real system deps (`opengl32`, `gdi32`, …) through. The C
runtime itself (`malloc`, `__chkstk`, …) comes from `ucrt`+`vcruntime`, which the
static auto-detection already links.

> **Caveat — libraries that don't self-declare their deps.** Honoring only pulls
> in what the `.lib` *records*. A library that uses Win32 APIs without
> `#pragma comment(lib, …)` won't list them, so you still link those yourself. The
> prebuilt **static raylib** is the classic case: it embeds `winmm` but not the
> GUI/GL libraries glfw uses, so a complete static-raylib build is:
>
> ```skarn
> app := b.executable("app", "main.sk");
> app.link("raylib");                 // raylib.lib detected → CRT auto-linked
> app.link("opengl32"); app.link("gdi32"); app.link("user32");
> app.link("shell32"); app.link("winmm");   // raylib's GUI deps it doesn't declare
> b.default(app);
> ```
>
> Run it from the folder that holds `raylib.lib` (or add `app.lib_path("…")`). The
> **DLL** distribution avoids the whole list — its `.dll` already carries the CRT
> and these dependencies, so prefer it when you can.

**Opting out — `game.no_default_libs()`.** If you'd rather keep the strict, minimal
linking and control every dependency yourself, call `no_default_libs()`; then the
library's `/DEFAULTLIB` directives are ignored and you list system deps explicitly:

```skarn
game.lib_path("vendor/raylib/lib-static");
game.no_default_libs();
game.link("opengl32"); game.link("gdi32"); game.link("user32");
game.link("winmm"); game.link("shell32");
```

A static/dynamic toggle then needs nothing extra in the default path:

```skarn
if b.option("static") {
    game.lib_path("vendor/raylib/lib-static");   // static archive → CRT + its deps auto
} else {
    game.lib_path("vendor/raylib/lib-dynamic");  // import lib → DLL auto-copied
}
```

#### Forcing static when both libraries exist

You can't make an import library link statically — it has no code in it, only a
pointer to the DLL. So "forcing static" means **making the linker pick the static
archive**, which you control by what's on the search path:

- If the static and import `raylib.lib` live in **different folders**, only add the
  static folder to `lib_path` (or list it first — the first `raylib.lib` found
  wins). The build sees a static archive → static link.
- If the two have **different names** (`raylib.lib` static, `raylibdll.lib`
  import), just `link("raylib")` vs `link("raylibdll")` — the name picks the file.

To make the intent safe, call **`game.static_link()`**: if the `raylib.lib` actually
resolved on your path turns out to be an *import* library, you get a clear warning
(`requested static linking, but '…/raylib.lib' is an import library — the link will
be DYNAMIC`) instead of silently shipping a dynamic build.

### Cross-platform

That API is deliberately platform-agnostic, so the same `build.sk` will work
unchanged once Skarn grows other targets. The intended mapping:

| build.sk | Windows (today) | Linux (planned) | macOS (planned) |
|---|---|---|---|
| `link("raylib")` | `raylib.lib` | `-lraylib` → `libraylib.so`/`.a` | `-lraylib` → `libraylib.dylib`/`.a` |
| `link_mode(.dynamic)` | import lib + ship `.dll` | `.so` + rpath | `.dylib` + rpath |
| `link_mode(.static)` | archive + CRT | `.a` + libc | `.a` + libSystem |
| `runtime_file(x)` | copy next to exe | (rpath usually suffices) | (rpath) |
| `link_libc()` | ucrt + vcruntime | the system libc/crt | libSystem |

**Skarn only emits and links Windows today** (COFF objects, `lld-link`, a Win64-only
ABI in `backend/llvm/abi.zig`, PE output). Reaching Linux/macOS needs, in order:

1. **Target selection** (`-target x86_64-linux-gnu`, …) — LLVM emits ELF/Mach-O
   for free once the triple is chosen.
2. **ELF / Mach-O linking** via `ld.lld` / `ld64.lld` (lld already ships both).
3. **The SysV / AArch64 aggregate ABI** — the largest piece; SysV's by-value
   struct classification (eightbyte SSE/INTEGER) is more involved than Win64's
   size-based rule, so it's a second ABI backend alongside `abi.zig`.
4. Per-platform runtime + entry conventions (`runtime/linux.sk` exists already).

None of that requires changing a `build.sk` — the link-mode/`runtime_file`/named-
library design above absorbs it.

## Generating bindings from a C header

`skarn bindgen` parses an arbitrary C header with libclang and emits a Skarn module:

```sh
skarn bindgen raylib.h --lib raylib -o raylib.sk
```

It maps:

- C functions → `#extern("<lib>", "<name>") pub name :: fn(...) -> ...;`
- C structs   → `pub Name :: struct { ... }`
- C enums     → `pub CONST :: <value>;` (plus a `pub Name :: i32` alias)
- C typedefs  → `pub Name :: <type>;`
- and a leading `#system_library("<lib>")`

Then use it like any module:

```skarn
#import raylib.*;

main :: fn() -> i32 {
    InitWindow(800, 450, "skarn + raylib".ptr);
    // ...
    return 0;
}
```

Options: `--lib <name>` sets the import-library name (default: the header stem),
`-o <file>` sets the output path, `-I<dir>` / `-D<sym>` are forwarded to clang,
and anything after `--` is passed to clang verbatim (e.g. extra `-isystem` paths
for libraries that include system headers). `skarn bindgen` requires an
LLVM-enabled build (libclang ships in the same SDK).

It also maps **object-like `#define` constants**: a plain numeric/string macro
becomes `pub NAME :: <value>;`, and a compound-literal macro (e.g. raylib's
`#define RAYWHITE CLITERAL(Color){ 245,245,245,255 }`) becomes a comptime-folded
typed constant, so colors and flags Just Work:

```skarn
__lit_RAYWHITE :: fn() -> Color { return .{ 245, 245, 245, 255 }; }
pub RAYWHITE :: #run __lit_RAYWHITE();
```

### Harder constructs

bindgen handles the awkward parts of real headers too:

- **Function pointers / callbacks** become a real Skarn function type, expanded
  inline at the use site (Skarn has no `Name :: fn(...)` type-alias form):
  `void set_logger(LogCallback)` → `pub set_logger :: fn(cb: fn(i32, [*]const u8) -> void);`.
  You can pass a Skarn function as the callback and C will call back into it.
- **Unions** and **bitfield structs** become a size- and alignment-correct opaque
  blob (`#align(A) struct { _bytes: [N]u8 }`) so by-value passing stays ABI-correct
  (you read the contents via casts).
- **Opaque / forward-declared types** (`typedef struct Foo Foo;` handles) become
  `pub Foo :: opaque;`, so `*Foo` resolves and the module always compiles.
- **Variadic** functions bind their fixed parameters and carry a `// note:` flag
  (the `...` itself isn't representable).
- `long double` maps to `f64` (they're identical on Win64).

**Still not handled:** function-like / expression `#define` macros (e.g.
`#define DEG2RAD (PI/180.0)`), and the variadic `...`. Skim generated bindings
for an unusually complex header before relying on them.
