# dll — a shared library with exported symbols

Proves the plumbing a native plugin needs: `b.shared` emits a real DLL, `#export`
puts the symbol in its export table under the name you gave, and a foreign process
can resolve and call it.

```
gabbro build
```

Verified with `llvm-readobj --coff-exports`:

```
Export { Ordinal: 1  Name: gab_add     RVA: 0x2090 }
Export { Ordinal: 2  Name: gab_version RVA: 0x20A0 }
```

and by loading it from an unrelated process:

```python
import ctypes
dll = ctypes.CDLL(r"...\gabdll.dll")
dll.gab_add.argtypes = [ctypes.c_int32, ctypes.c_int32]
dll.gab_add.restype  = ctypes.c_int32
dll.gab_add(20, 22)          # 42
```

## What this does not yet cover

A CLAP or VST3 plugin needs more than exported functions. Its entry point is an
exported **data** symbol — `extern const clap_plugin_entry_t clap_entry;` — a static
struct holding function pointers that the host reads and calls through.

Gabbro cannot emit that yet. Only scalar globals survive to static storage; a global
struct, array, or function pointer is rejected with "constant initializer could not
be folded at compile time". The same shapes all work fine as locals: struct literals,
function pointers, calling through a function-pointer field, returning a pointer to a
struct. It is specifically static storage that is missing.

One compiler feature covers it — constant aggregates in static storage — and the same
feature is what a top-level `#run` producing a table needs. See "Known gaps" in
[ROADMAP.md](../../ROADMAP.md).

Until then, a plugin would need a small C shim to define the entry symbol and forward
into the Gabbro exports this example demonstrates.
