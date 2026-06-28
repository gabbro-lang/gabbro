# Package management — design

> Status: **design**. The build system (doc 10) already runs `build.sk` in the
> comptime VM, hands each build hook a **capability set**, models a content-hashed
> build graph, and has a `--frozen` lockfile in its vision. This document designs
> the missing half: how dependencies are *declared, fetched, resolved, cached,
> trusted, and granted authority* — skarn's package manager.

## 0. What we take from Zig, and what we don't

Zig's package manager gets the fundamentals right, and skarn keeps them:

- **Decentralized.** No mandatory central registry. A dependency is a URL (git or
  tarball) plus a content hash. Anyone can host a package.
- **Content-addressed & reproducible.** The hash *is* the identity; builds are
  byte-for-byte reproducible and offline once fetched.
- **A global, deduplicated cache.** Fetch once, share across every project.

What we deliberately do **differently**:

- **The manifest is skarn, not a side-car data file.** Zig split `build.zig.zon` out
  of `build.zig` so deps can be read without running code. skarn doesn't need the
  split: it runs `build.sk` in the comptime VM, so it reads deps by running the
  manifest **in a fully-sandboxed query mode** (all capabilities denied, only
  `b.dependency(...)` calls recorded). One language, one file, still safe to
  introspect.
- **Capabilities are the package boundary** — the headline (§1). Zig's fetched
  build scripts run with full host authority, same as `build.rs`. skarn's don't, and
  *can't*.
- **No SAT solver, ever.** Resolution is add-time and deterministic (§4).

The thesis in one line: **a dependency is a content-hashed, capability-bounded
sub-build.**

## 1. Capabilities are the package boundary

Every dependency's `build.sk` receives a `*Caps` it cannot forge or widen
(doc 10 §5.1). The package manager makes that the *contract you see when you add a
dependency*, not a footnote:

```text
$ skarn add github.com/ana/imagelib
  fetching … 4f9c…a1 (312 KiB)
  imagelib requests capabilities:
      fs.read   "assets/"        — read its bundled lookup tables
      net       (none)
      shell     (none)
  grant fs.read for assets/? [y/N]
```

A package **declares** the authority it needs; the root build **grants** it
explicitly; the **VM enforces** it. A logging library that suddenly wants `net`
in a patch release shows up as a capability diff in review — the supply-chain
attack surface is *visible and bounded by construction*, not by audit-after-the-fact.

```skarn
// the root build grants narrowly:
dep := b.dependency("imagelib", .{ .hash = "4f9c…a1" });
dep.allow(.fs_read, "assets/");        // nothing else reaches the OS
```

This is the structural answer to the `build.rs`/`npm postinstall` problem: an
ambient-authority hole replaced by an explicit, reviewable grant.

## 2. Identity & addressing

A package is identified by `(name, content-hash)`:

- **`hash`** — the identity. A BLAKE3 (or SHA-256) digest of the package's file
  tree, normalized (sorted paths, fixed mode bits) so it's stable across hosts.
  Two packages may share a `name` from different sources; the hash disambiguates.
- **`name`** — for humans and for the `#import pkg.module` namespace.
- **`source`** — *where* to fetch (a git ref or tarball URL). The source is a hint;
  the hash is law. If the bytes don't hash to the pin, the fetch is rejected.

### Federated indexes (optional, not central)

A name like `imagelib` resolves to a source through an **index** — but the index
is just a skarn file mapping names to sources, and *anyone can host or fork one*:

```skarn
// a community index file (itself content-pinned in your build)
index :: .{
    .{ "imagelib", "github.com/ana/imagelib", "4f9c…a1" },
    .{ "json",     "git.sk.dev/std-json",     "be20…77" },
};
```

You point at the indexes you trust (`b.index("git.sk.dev/registry@<hash>")`);
there is no privileged global namespace to squat or capture. Direct URL deps need
no index at all. This is federation, not centralization — closer to Nix channels
than to crates.io.

## 3. The manifest: declarative deps in `build.sk`

Dependencies are ordinary `build.sk` code, but written in a shape the manager can
extract without trusting it:

```skarn
#import std.build;

build :: fn(b: *Build) {
    json := b.dependency("json", .{ .hash = "be20…77" });
    img  := b.dependency("imagelib", .{ .hash = "4f9c…a1" })
              .allow(.fs_read, "assets/");

    app := b.executable("app", "src/main.sk");
    app.use(json);          // brings `json`'s modules into scope as `json::…`
    app.use(img);
    b.default(app);
}
```

**Query mode.** To learn the dependency graph, `skarn` runs `build` on the comptime
VM with a `Caps` that denies *everything* and a `Build` that records, rather than
executes, side effects. The `b.dependency(...)` / `.allow(...)` calls are captured
as data; nothing is fetched, no file is touched, no code with authority runs. The
manifest is live skarn — and still as safe to inspect as a static `.zon`.

## 4. Resolution & the lockfile — deterministic, no solver

Resolution happens **at `add`/`update` time, online**, and is then *frozen*:

1. `skarn add <name|url>` resolves the name through your indexes (or takes the URL),
   fetches, hashes, and writes the pin into both `build.sk` (the `.hash`) and the
   lockfile.
2. A dependency's own deps are resolved transitively the same way, each pinned to
   a hash.
3. **Builds never resolve.** They read hashes from the lockfile and fetch-by-hash
   (cache hit ⇒ offline). `--frozen` fails if the lockfile would change — CI-safe.

When two deps pin *different* hashes of the same name, that's **not** a conflict to
solve: skarn keeps both (they're distinct content), each in its own namespace, exactly
as monomorphization keeps `Pair(i32)` and `Pair(f64)` distinct. Diamond
"conflicts" simply don't arise; there is nothing for a SAT solver to do. If you
*want* them unified, `skarn update` picks the higher version at add-time (a Go-style
**minimum-version selection** done once, offline-frozen after) — never a
backtracking search during the build.

The lockfile is **human-readable skarn**, not an opaque blob — diffable in review:

```skarn
// skarn.lock  — generated; review the hashes and capability grants here
lock :: .{
    .{ .name = "json",     .hash = "be20…77", .src = "git.sk.dev/std-json",   .caps = .{} },
    .{ .name = "imagelib", .hash = "4f9c…a1", .src = "github.com/ana/imagelib",
       .caps = .{ .{ .fs_read, "assets/" } } },
};
```

## 5. The cache — content-addressed, shared

Fetched packages live in a content-addressed store (`~/.sk/pkg/<hash>/`), shared
by every project on the machine and immutable once written. Consequences:

- **Dedup**: one copy of `json@be20…77` regardless of how many projects use it.
- **Integrity**: a path *is* its hash; tampering is detected on use.
- **Build-graph reuse** (doc 10 §5.2): a dependency is a content-hashed node, so an
  unchanged dep's *compiled* artifacts cache too — not just its source. Adding a
  pinned dep you've built before is nearly free.

`skarn vendor` copies the resolved tree into `vendor/` for air-gapped/committed builds
(`b.require_path(...)` then reads from there, doc 10 §5.1).

## 6. CLI surface

```text
skarn add <name|url> [@version]   resolve, fetch, pin into build.sk + lock; prompt for caps
skarn update [name]               re-resolve to newer compatible versions, re-freeze
skarn remove <name>               drop a dependency
skarn why <name>                  show who pulls a dep in + its capability grants
skarn vendor                      copy resolved deps into ./vendor for committed builds
skarn verify                      re-hash the cache/lock; fail on any drift (CI integrity gate)
skarn caps                        print the full granted-capability set across the dep tree
```

`skarn add`/`update` are the only online, resolving commands; `skarn build` is offline
and hash-pinned. `skarn caps` is the supply-chain review tool — the whole authority
surface of your dependency tree on one screen.

## 7. Trust model (the supply-chain story, end to end)

1. **Identity by content.** You depend on *bytes*, pinned by hash — not a mutable
   tag a maintainer can repoint.
2. **Authority by grant.** A dep gets exactly the capabilities you hand it; the VM
   enforces it; new asks appear as a reviewable diff (`skarn caps`, `skarn why`).
3. **Reproducibility by lock.** `--frozen` + the content-addressed store make a
   build bit-identical and offline.
4. **Federation, not a chokepoint.** Indexes are forkable skarn files; no central
   registry to compromise, squat, or take down.
5. **Optional signing.** An index entry (or a package) may carry a maintainer
   signature; `b.index(..).require_signed()` rejects unsigned resolves. Layered on
   top — hashes already give integrity; signatures add provenance.

## 8. What we deliberately do NOT build

- **No SAT/PubGrub version solver.** Distinct hashes coexist; updates are a
  one-shot offline MVS pick. Determinism over cleverness.
- **No mandatory central registry.** Federated indexes + direct URLs.
- **No ambient-authority build scripts.** A dependency physically cannot reach the
  network, shell, or arbitrary filesystem without a grant.
- **No bespoke manifest language.** It's skarn, read via sandboxed query mode.

## 9. Build order

1. Content-addressed fetch + store + hashing; direct-URL deps; the lockfile.
2. `b.dependency`/`.use` in `build.sk` + query-mode extraction on the VM.
3. Capability declaration + grant + VM enforcement wiring (extends doc 10 §5.1).
4. `skarn add`/`update`/`why`/`caps` CLI; `--frozen`/`verify`.
5. Federated indexes + name resolution.
6. Compiled-artifact caching of deps (build-graph integration, doc 10 §5.2).
7. Optional signing.

Each layer is useful alone: (1)–(2) already give reproducible, hash-pinned,
direct-URL dependencies; capabilities (3) are what make skarn's package manager a
*different thing* rather than a smaller Cargo.
