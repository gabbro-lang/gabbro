# Gabbro Modules

This directory contains Gabbro's standard-library and future package modules.

The compiler resolves:

```gabbro
#import std.mem;
```

to `std/mem.gab` beneath its configured modules root. The compiler defaults to
this sibling `gabbro-modules` directory; use `-Dstdlib-root=<path>` when building the
compiler to choose another location.

## std.mem

`std.mem` provides safe typed-slice operations. Every public operation is also
an import-scoped extension method because its first value parameter is named
`self`:

```gabbro
#import std.mem.{copy, eql_bytes, fill, index_of, zero};

copy(u8, destination, source);
destination.copy(u8, source);
values.fill(i32, 0);
found := values.index_of(i32, 42);
bytes.zero();
```

Generic functions currently take their element type explicitly. `copy` copies
the shorter of the source and destination lengths, returns the copied count,
and requires non-overlapping slices.
