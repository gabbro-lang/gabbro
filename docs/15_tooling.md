# Tooling & the language server — design

`gabbro lsp` works: diagnostics, completion, hover, go-to-definition, and document
symbols — §8 wires it into your editor. The `#test` comptime lane works too
([docs/17](17_testing.md)). A tree-sitter grammar (`tree-sitter-gabbro/`) and a Zed
extension (`zed-gabbro/`) handle highlighting. A formatter, doc generator, runtime
test lane, and REPL aren't built yet.

## 0. The principle: the compiler is a library

gabbro's tooling does **not** re-parse or re-model the language. The compiler is
already a library (`gabbro_compiler`) whose frontend is reusable and, crucially,
*tolerant*:

- `parseSource(alloc, file, src) -> ast.Module` — the AST.
- `sema_mod.collectSymbols(alloc, module) -> SymbolTable` — names + scopes.
- `sema_mod.checkTypesTolerant(alloc, module, &syms, src, file) -> TypeEnv` —
  type-checks and **returns a partial result even on errors** (it was built for
  the two-pass `#insert` rail). That is exactly what an editor needs: code is
  broken most of the time you're typing it.

The `TypeEnv` already carries everything the tools below want, keyed by AST node
id ([src/sema.zig](../src/sema.zig)):

| Data | Field | Powers |
| --- | --- | --- |
| type at a node | `expr_types: NodeId → Ty` | hover, semantic tokens, signature help |
| name → its symbol | `expr_symbols: NodeId → SymbolId` | go-to-definition, references, rename |
| method call → method | `extension_calls: NodeId → SymbolId` | go-to-def on `x.foo()` |
| errors/warnings | `diagnostics: []Diagnostic` (line:col, severity) | live diagnostics, quick-fixes |
| symbol metadata | `Symbol{ name, kind, span, file }` | definition location, outline, completion |
| scopes | `SymbolTable.resolve*` | scope-aware completion |

So every tool is a *thin* consumer of the frontend, sharing one model of the
language. No second parser to drift.

## 1. `gabbro lsp` — the language server

A `gabbro lsp` subcommand speaking LSP (JSON-RPC over stdio). One server, every
editor (Zed/Neovim/Helix/VS Code each need only a few lines of client config).

### 1.1 Document lifecycle

- Keep an in-memory store of open documents (uri → text + version).
- On open/change: lex → parse → `checkTypesTolerant`, cache the `(Module, TypeEnv,
  SymbolTable)` for that document. gabbro compiles in **milliseconds**, so a full
  re-check per keystroke (debounced) is fine for v1; salsa-style query caching is
  a later optimization.
- Publish `diagnostics` immediately — they already have spans and severities.

### 1.2 Position mapping

LSP positions are UTF-16 `(line, character)`; gabbro spans are byte offsets.
`Span.line_col(source)` ([src/lexer/span.zig](../src/lexer/span.zig)) already
yields `(line, col)` — wrap it with a byte↔UTF-16 column converter (one small
utility, exercised by a property test against multibyte source).

### 1.3 Feature map (all backed by data that already exists)

| LSP request | Implementation |
| --- | --- |
| `publishDiagnostics` | `TypeEnv.diagnostics` → LSP diagnostics |
| `hover` | node under cursor → `expr_types[node]` → `formatTy`, plus the symbol's leading doc comment |
| `definition` | `expr_symbols[node]` / `extension_calls[node]` → `Symbol.span`/`.file` |
| `references` / `rename` | build the reverse index `SymbolId → [NodeId]` while walking; rename rewrites every span |
| `completion` | scope-visible symbols at the cursor + **member completion** (the `expr_types` of the `.`-base gives the struct → its fields/methods) + `core::`/`#attribute` builtins |
| `signatureHelp` | the call being typed → `fn_sigs[symbol]` → params + active arg |
| `documentSymbol` | walk the `Module` top-level + in-struct methods (the semantic cousin of `outline.scm`) |
| `formatting` | delegate to `gabbro fmt` (§2) |
| `semanticTokens` | classify each node by symbol kind + comptime-ness (§1.5) |
| `codeAction` | turn diagnostics into fixes (§1.4) |

### 1.4 Quick-fixes from the diagnostics engine

The diagnostics already *suggest*; the LSP turns those into one-click fixes:

- "unknown type `Poimt`; did you mean `Point`?" → a rename edit. (The
  did-you-mean engine landed in [sema.zig](../src/sema.zig) — `suggestTypeName`.)
- "non-exhaustive match: variant `.X` not handled" → insert the missing arm
  (sema already enumerates the missing variants).
- "`fail` used in a function without a `!` error return type" → add the `! Err`.
- A struct with hand-written `eq`/`hash` → offer `#derive(Eq, Hash)` instead.

This is where reusing the compiler pays off: the analysis that produces the error
already knows the fix.

### 1.5 The gabbro differentiators

What a generic LSP-over-tree-sitter can't do, but gabbro's reusable, comptime-capable
frontend can:

- **Comptime-aware navigation.** `#derive`, `#compiler` hooks, and macros
  generate real declarations at comptime. The server runs that generation pass
  (it already happens in the pipeline) and indexes the **generated** symbols — so
  hover/go-to-def/completion work on a derived `eq`/`hash`/`format` method, not
  just hand-written ones. (Rust-analyzer fights proc-macro opacity; gabbro's
  generation is structured AST, so the server simply sees the output.)
- **Type-aware semantic tokens.** Beyond tree-sitter's syntactic colors, color by
  *meaning*: distinguish a type from a value, a `#run`/comptime-constant from a
  runtime one, an `#extern` symbol, a region/`zone` handle. All derivable from
  `expr_types` + `Symbol.kind`.
- **Region/lifetime hints.** Inlay hints showing which `*Arena` a `Vec`/`Map` is
  bound to, or flagging a value that escapes its region — gabbro's memory model made
  visible inline.
- **Capability hints in `build.gab`.** Show, inline, which capabilities a
  dependency requests (ties into the package manager, doc 16).

### 1.6 Scope

v1: diagnostics, hover, definition, completion, document symbols, formatting.
v2: references/rename, signature help, semantic tokens, code actions.
v3: comptime-aware indexing, inlay hints, workspace-wide symbol search.

## 2. `gabbro fmt` — the canonical formatter

Opinionated and **config-free** (the gofmt/`zig fmt` philosophy): one true style,
no bikeshedding. Idempotent: `fmt(fmt(x)) == fmt(x)`.

- Implementation: reuse the parser, then pretty-print the AST. The one hard part
  is **comment preservation** — comments aren't in the AST. Approach: a
  token-anchored printer that re-emits from the AST but threads trailing/leading
  comments by their source position relative to the nearest node. (Alternatively a
  CST/loss-less parse; the AST+anchoring path is lighter and matches what exists.)
- Drives the LSP `formatting`/`rangeFormatting` requests and a `--check` mode for
  CI (`gabbro fmt --check` exits non-zero on unformatted files).

## 3. `gabbro doc` — reflection-driven documentation

gabbro's reflection is the unfair advantage here. `compiler_decls()` and `type_info`
already expose every declaration's shape; doc generation reads those plus the
leading doc comments and emits HTML/Markdown.

- It shows **derive-generated** API (the `eq`/`hash`/`format` a `#derive` added),
  because those are real decls in the program — documentation that matches what
  actually compiles.
- It can render **comptime-evaluated constants** with their *values* (`#run`-folded
  consts), not just their declarations.
- Output is a static site (or Markdown for embedding). A `b.doc` build step makes
  it a first-class, cacheable node in the build graph (doc 10 §5).

## 4. `gabbro test` — the test runner

Design a `#test` attribute: functions marked `#test` are discovered, compiled into
a harness, and run with pass/fail + timing. The vm-corpus harness already proves
the shape (`tests/compiler/vm_corpus.zig`).

- **Two execution modes, gabbro's twist:** a pure `#test` with no I/O can run **at
  compile time on the comptime VM** (instant, hermetic), while tests needing the
  OS run as a built executable. The attribute can hint (`#test(comptime)`), or the
  runner tries comptime first and falls back.
- `gabbro test` (and the `b.test` build step) discover, build, and report. Filters
  (`gabbro test --filter substr`), and a TAP/JSON reporter for CI.

## 5. `gabbro repl` — interactive evaluation

The comptime VM (`src/vm/`) already evaluates gabbro to real values over a modeled
host memory. A REPL is an interactive driver over it: enter a decl or expression,
the VM evaluates it, the result prints. Distinctive because it's the *same engine*
that runs `#run`/`#compiler` — the REPL is comptime gabbro, live. Good for exploring
`std`, prototyping a generic, or inspecting `type_info`.

## 6. Editor integrations — one grammar, one server

- **Syntax**: `tree-sitter-gabbro/grammar.js` is the single syntactic source of truth.
  It already feeds the Zed extension; the same grammar + queries drive
  nvim-treesitter, Helix, and VS Code (tree-sitter, with a TextMate grammar as a
  no-WASM fallback). Keep the highlight/indent/bracket/outline `.scm` queries in
  the grammar repo; editors consume them verbatim.
- **Semantics**: every editor points its LSP client at `gabbro lsp`. Syntax from
  tree-sitter, meaning from the server — no per-editor logic.
- **Distribution**: publish the grammar (tree-sitter), the Zed/VS Code extensions,
  and ship `gabbro lsp` inside the `gabbro` binary so "install gabbro" gives you the server
  for free.

## 7. Build order

1. `gabbro fmt` (smallest, unblocks LSP formatting + CI style).
2. `gabbro lsp` v1 (diagnostics + hover + definition + completion) — the highest-impact
   tool, almost entirely a thin wrapper over `checkTypesTolerant`.
3. `#test` + `gabbro test`.
4. `gabbro doc` (reflection-driven).
5. LSP v2/v3 (rename, semantic tokens, code actions, comptime-aware indexing).
6. `gabbro repl`.

The throughline: because the compiler is already a tolerant, reflection-capable
library, each tool is small. The investment is the **library seams**
(position mapping, a reference index, comment-anchoring) — not re-implementing the
language five times.

## 8. Using `gabbro lsp` today

`gabbro lsp` is built into the `gabbro` binary and speaks LSP over stdio. It gives live
diagnostics, scope completion, hover, go-to-definition, and a document outline.
Point any LSP-capable editor at `gabbro lsp`.

**Helix** — `~/.config/helix/languages.toml` (zero compilation):

```toml
[language-server.gab]
command = "gabbro"
args = ["lsp"]

[[language]]
name = "gabbro"
scope = "source.gab"
file-types = ["sk"]
roots = ["build.gab"]
language-servers = ["gabbro"]
comment-tokens = ["//"]
```

**Neovim** — in your config:

```lua
vim.filetype.add({ extension = { sk = "gabbro" } })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "gabbro",
  callback = function()
    vim.lsp.start({ name = "gabbro", cmd = { "gabbro", "lsp" },
      root_dir = vim.fs.root(0, { "build.gab", ".git" }) })
  end,
})
```

**Zed** — the `zed-gabbro/` extension declares the server (`[language_servers]` +
the Rust glue in `zed-gabbro/src/lib.rs`, which launches `gabbro lsp` from your `PATH`).
Install it as a dev extension; building it needs a Rust toolchain (Zed compiles
the extension to WASM). VS Code support is a thin client wrapper (future).

> Smoke-test the protocol without an editor: `python tests/lsp_smoke.py` drives a
> full `initialize` → `didOpen` → `completion`/`hover`/`definition`/`documentSymbol`
> exchange against the built binary and prints the results.

## Diagnostics in the terminal

A diagnostic is a header, a location, a source snippet with the offending span
underlined, then any `note:`/`help:` lines:

```text
error: unknown type `Poin`
  --> demo.gab:4:8
  │
4 │     p: Poin = .{ .x = 1, .y = 2 };
  │        ^^^^ not a known type
  = help: did you mean `Point`?
```

`src/diagnostic.zig` renders it. The `Diagnostic` carries the parts: a primary span
plus label, secondary `labels` (other underlines, or the frames of a trace),
`notes`, and `helps`. `sema` attaches them through `emitErrorRich`: a type mismatch
underlines the value and names the expected type; an unknown name, function, or type
gets a `help: did you mean …?` (a Levenshtein search over the locals in scope,
top-level functions and consts, and the type names).

Color is on when stderr is a console, off when it's a pipe or file, so captured
output stays plain. `NO_COLOR` forces it off, `GABBRO_COLOR=1` forces it on (handy
when paging). `src/style.zig` makes the call and enables VT processing on Windows.
