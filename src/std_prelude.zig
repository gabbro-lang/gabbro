//! Embedded stdlib sources injected as a compiler prelude.
//!
//! A `zone X: Arena {}` handle is an ordinary `std.heap.Arena`, so any module
//! that uses a zone block depends on std.heap. To make that work uniformly —
//! including the inline `compile(source)` path that never reads from disk — the
//! relevant stdlib sources are embedded in the compiler and prepended to the
//! module when a zone is used (and std.heap isn't already imported).
//!
//! These are the same files served from `lib/std/` via `#import`; embedding
//! keeps a single source of truth. `ptr` is pulled in too because `heap`
//! depends on `std.ptr.align_up`.

/// `lib/std/heap.sk` — the bump arena (Arena, make/reserve/fixed, alloc*, new*).
pub const heap_src = @embedFile("std_heap_skarn");

/// `lib/std/ptr.sk` — pointer helpers; `heap` uses `align_up`.
pub const ptr_src = @embedFile("std_ptr_skarn");
