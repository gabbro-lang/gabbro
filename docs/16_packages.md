# Package management (design)

Not built yet. The build system (doc 10) already runs `build.sk` in the comptime
VM, hands each build hook a capability set, and models a content-hashed build graph.
This is the other half — declaring, fetching, resolving, caching, and granting
authority to dependencies.

Content-addressed and decentralized, the Zig fundamentals: a dependency is a URL
(git or tarball) plus a content hash, fetched once into a shared global cache,
reproducible offline. Two things differ here. The manifest is `build.sk`, not a
side-car data file — read by running it in the VM under a deny-all capability set
that only records `b.dependency(...)` calls. And a dependency's build code runs with
no ambient authority. It gets exactly the capabilities the root build grants, and
the VM enforces that.

## Capabilities are the package boundary

Every dependency's `build.sk` receives a `*Caps` it can't forge or widen (doc 10
§5.1). You see the contract at add time:

```text
$ skarn add github.com/ana/imagelib
  fetching … 4f9c…a1 (312 KiB)
  imagelib requests capabilities:
      fs.read   "assets/"        — read its bundled lookup tables
      net       (none)
      shell     (none)
  grant fs.read for assets/? [y/N]
```

The package declares the authority it needs, the root build grants it, the VM
enforces it.

```skarn
dep := b.dependency("imagelib", .{ .hash = "4f9c…a1" });
dep.allow(.fs_read, "assets/");        // nothing else reaches the OS
```

A logging library that asks for `net` in a patch release is a capability diff in
review, caught before the merge instead of after the incident.

## Identity

A package is `(name, content-hash)`:

- `hash` — the identity. BLAKE3 (or SHA-256) over the normalized file tree (sorted
  paths, fixed mode bits), stable across hosts.
- `name` — for humans and the `#import pkg.module` namespace.
- `source` — where to fetch (git ref or tarball URL). A hint. If the bytes don't
  hash to the pin, the fetch is rejected.

Names resolve through an index, itself a Skarn file mapping names to sources,
content-pinned and forkable. You point at the indexes you trust
(`b.index("git.sk.dev/registry@<hash>")`). Direct URL deps skip the index entirely.

## The manifest

Deps are `build.sk` code, in a shape the manager extracts without trusting it:

```skarn
build :: fn(b: *Build) {
    json := b.dependency("json", .{ .hash = "be20…77" });
    img  := b.dependency("imagelib", .{ .hash = "4f9c…a1" })
              .allow(.fs_read, "assets/");

    app := b.executable("app", "src/main.sk");
    app.use(json);          // json's modules in scope as json::…
    app.use(img);
    b.default(app);
}
```

Query mode: to read the graph, `skarn` runs `build` on the VM with a deny-all `Caps`
and a `Build` that records side effects instead of performing them. The
`b.dependency(...)` / `.allow(...)` calls land as data — nothing fetches, no file is
touched.

## Resolution and the lockfile

Online at `add`/`update` time, then frozen:

1. `skarn add <name|url>` resolves through your indexes (or takes the URL), fetches,
   hashes, writes the pin into `build.sk` and the lockfile.
2. Transitive deps resolve the same way, each hash-pinned.
3. Builds never resolve. They fetch by hash from the lockfile — cache hit, offline.
   `--frozen` fails if the lockfile would change.

Two deps pinning different hashes of the same name is not a conflict. They're
distinct content, each in its own namespace, the way monomorphization keeps
`Pair(i32)` and `Pair(f64)` apart — nothing for a solver to do. Want them unified?
`skarn update` does a one-shot minimum-version pick at add time, frozen after.

The lockfile is readable Skarn, diffable in review:

```skarn
lock :: .{
    .{ .name = "json",     .hash = "be20…77", .src = "git.sk.dev/std-json",   .caps = .{} },
    .{ .name = "imagelib", .hash = "4f9c…a1", .src = "github.com/ana/imagelib",
       .caps = .{ .{ .fs_read, "assets/" } } },
};
```

## The cache

Fetched packages live in `~/.sk/pkg/<hash>/`, shared by every project, immutable
once written. One copy of `json@be20…77` machine-wide. A path is its hash, so
tampering shows up on use. A dep is a content-hashed build-graph node (doc 10 §5.2),
so an unchanged dep's compiled artifacts cache too — re-adding a dep you've built
before is nearly free.

`skarn vendor` copies the resolved tree into `vendor/` for air-gapped builds.

## CLI

```text
skarn add <name|url> [@version]   resolve, fetch, pin into build.sk + lock; prompt for caps
skarn update [name]               re-resolve to newer compatible versions, re-freeze
skarn remove <name>               drop a dependency
skarn why <name>                  who pulls a dep in, and its grants
skarn vendor                      copy resolved deps into ./vendor
skarn verify                      re-hash cache/lock; fail on drift
skarn caps                        the granted-capability set across the dep tree
```

`add`/`update` are the only online commands. `skarn build` is offline and
hash-pinned. `skarn caps` puts the whole authority surface of the dep tree on one
screen.

## Trust model

- Identity by content — you depend on bytes pinned by hash, not a mutable tag a
  maintainer can repoint.
- Authority by grant — a dep gets exactly the capabilities you hand it; new asks
  appear in `skarn caps` / `skarn why`.
- Reproducibility by lock — `--frozen` plus the content-addressed store make a build
  bit-identical and offline.
- Federation — indexes are forkable Skarn files, no central registry.
- Optional signing — an index entry or package may carry a maintainer signature;
  `b.index(..).require_signed()` rejects unsigned resolves.

No SAT solver, no central registry, no ambient-authority build scripts, no bespoke
manifest language.
