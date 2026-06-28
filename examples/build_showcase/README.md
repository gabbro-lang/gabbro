# Build system showcase

A tour of the `std.build` API. Run these from this directory:

```sh
skarn build            # build the default artifact (app) into bin/
skarn build run        # build, then run it
skarn build --list     # list artifacts and steps
skarn build -Dtrace    # enable the `trace` build option (defines TRACE=1)
skarn build --release  # force release optimization
skarn build plugin     # build a specific artifact (the shared library)
```

[build.sk](build.sk) demonstrates: a workspace + `out_root`, a GUI executable
(`windowed()`), optimization levels, stack size, version/description/install
metadata, linking + raw linker flags, a configurable `-D` build option, a
companion shared library, a run step, a default, and the build `summary()`.

See [docs/10_build_system.md](../../docs/10_build_system.md) for the full reference.
