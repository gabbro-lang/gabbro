gabbro-lang — licensing
===================

Copyright (c) 2026 Christian Brendlin.

gabbro-lang is licensed per component. Which license applies to a given file is
recorded in that file's `SPDX-License-Identifier` header; this document explains
the split and, most importantly, what it means for programs you compile with gabbro.

The compiler — GPLv3
--------------------

The gabbro compiler itself — the Zig sources under `src/` (lexer, parser, semantic
analysis, IR, comptime VM, and the LLVM/gabld backends) — is licensed under the
GNU General Public License, version 3. See `LICENSE-GPLv3.txt`.

  SPDX-License-Identifier: GPL-3.0-or-later

If you distribute a modified gabbro *compiler*, the GPLv3 applies: you must make your
changes to the compiler available under the same terms.

The runtime, standard library, and everything emitted into your program — Apache-2.0
------------------------------------------------------------------------------------

Every component that the compiler injects into, links into, or generates inside a
compiled program is licensed under the Apache License, version 2.0. See
`LICENSE-APACHE-2.0.txt` and `NOTICE`. This covers:

  * `lib/`               — the gabbro standard library
  * `src/runtime/`       — the embedded platform runtime (`windows.gab`, `linux.gab`)
  * the compiler-injected prelude sources (heap, ptr, reflection, `Any`, the
    `Test` testing context, …), including those embedded as string data inside
    `src/std_prelude.zig` and `src/ast_prelude.zig`
  * code the compiler generates into your program (`#derive`, serde, the test
    harness, and similar synthesized declarations)

  SPDX-License-Identifier: Apache-2.0

What this means for your programs
---------------------------------

**Programs you compile with gabbro are NOT covered by the GPL.** A compiled gabbro program
contains your own source plus the Apache-2.0 runtime and standard library — it is
not a derivative work of the GPL-licensed compiler, and it carries no GPL
obligation. You may license and distribute your gabbro programs however you wish,
including as proprietary software.

This is the same outcome GCC provides through its "runtime library exception,"
reached here more simply: the runtime and standard library are permissively
licensed (Apache-2.0) rather than GPL, so no special exception is required.

Notes
-----

  * GPLv3 (not GPLv2) is used deliberately: the compiler embeds the Apache-2.0
    runtime/stdlib sources, and Apache-2.0 is compatible with GPLv3 but not with
    GPLv2. The compiler also links LLVM/LLD (Apache-2.0-with-LLVM-exception),
    which is likewise GPLv3-compatible.
  * The tree-sitter grammar (`tree-sitter-gabbro`) and the Zed extension (`zed-gabbro`)
    live in separate repositories under their own licenses and are not covered
    here.
  * When in doubt about a single file, the `SPDX-License-Identifier` header in
    that file is authoritative.
