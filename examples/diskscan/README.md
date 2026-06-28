# diskscan

A fast, multithreaded disk-usage analyzer for Windows — written in **skarn**, with
both a command-line tool and a native Win32 GUI browser. Think WinDirStat, but a
few hundred lines of skarn and no dependencies.

```
out/diskscan      [dir]     scan, print the biggest items + throughput  (console)
out/diskscan-gui  [dir]     browse the tree, recycle what you don't want (window)
```

![what it does](.) <!-- the GUI: sorted rows with %, size, a proportional bar, and the name -->

## Build

Built entirely with the skarn build system (`build.sk`):

```
skarn build            # build both exes into ./out (release)
skarn build run        # build + run the CLI on the current directory
skarn build gui        # build + launch the GUI
skarn build -Ddebug    # unoptimized build with safety checks
```

## What makes it fast

A full `C:` scan here is ~2.6 M files / 1.8 TB. The language is never the
bottleneck — skarn compiles to native code through LLVM, so the cost is the OS's
directory enumeration. diskscan pulls two levers to minimize that cost:

1. **Bulk directory reads.** Instead of `FindNextFile` (one entry per syscall),
   each directory is opened as a handle and drained with
   `GetFileInformationByHandleEx`, which returns *many* `FILE_FULL_DIR_INFO`
   records per call. A directory is read completely before we descend, so a
   single 64 KB buffer is reused for an entire subtree — **zero per-entry heap
   allocation**.

2. **Multithreading.** The root's immediate sub-directories are partitioned
   round-robin across one worker thread per CPU (`CreateThread`). Each worker
   owns a disjoint set of subtrees and its own arena, so the scan is **lock-free**
   — threads never touch each other's nodes. NTFS/SSD loves the concurrent reads.

The file size comes *free* with each directory record, so there is no second
`stat` per file.

## Layout

```
build.sk              two artifacts (console CLI + windowed GUI), versioned
src/
  win32.sk            kernel32 bindings: bulk reads, threads, CPU count
  node.sk             the directory tree (lazy-sorted children, tombstone delete)
  scan.sk             the scanner — both levers, builds the tree
  fmt.sk              human-readable sizes (1.5 GB, 870.4 KB, 42 B)
  cli.sk              CLI entry: scan + sorted report + throughput
  gui.sk             GUI entry: Win32 window, GDI drawing, navigation, delete
```

`cli.sk` and `gui.sk` are two `#entry` points over the **same** scanner and tree
— the build system compiles each into its own executable.

## The GUI

A real window: a registered class, a message loop, and GDI drawing — no toolkit.
Two panes side by side:

- **List** (left) — the current directory's children, biggest first, with a
  percent, a human size, a type-coloured bar, and the name (directories in blue).
- **Treemap** (right) — a **squarified treemap / heatmap** of the *whole* subtree.
  Every file is a rectangle sized by bytes and coloured by type (code, image,
  video, audio, archive, binary, docs, data); directories nest. This is the
  WinDirStat "block view", but flat and modern.

Extras that go past WinDirStat's classic UI:

- **Instant window + background scan** — the window opens immediately and shows an
  animated "Scanning…" screen while a worker thread builds the tree, then reveals
  the browser. No modal wait, even for a multi-minute `C:` scan.
- **Double-buffered** — the whole frame renders to an off-screen bitmap and blits
  in one `BitBlt` (with `WM_ERASEBKGND` suppressed), so there's no flicker and no
  visible partial redraw, even with a treemap of thousands of cells.
- **Hover to inspect** — point at any block and the status bar shows its full path
  and size; the block gets a white outline.
- **Click to jump** — click a block to navigate the list straight to its folder.
- **Colour legend** in the status bar.
- **Grow-in animation** — bars and treemap cells animate in (a 16 ms `SetTimer`
  loop that stops itself once settled, so it's idle when nothing moves).
- **View modes** — `Tab` cycles split → treemap-only → list-only.
- **Open in Explorer** (`O`) and **rescan** (`F5`).

| key | action | key | action |
|-----|--------|-----|--------|
| ↑ / ↓ / wheel | move selection | Enter / double-click | open directory |
| Backspace | go to parent | Delete | send to Recycle Bin |
| Home / End | first / last | Tab | cycle view mode |
| F5 | rescan | O | open current folder in Explorer |
| mouse | hover + click the treemap | Esc | quit |

Deletes go through `SHFileOperation` with `FOF_ALLOWUNDO`, so they land in the
Recycle Bin (recoverable) after a confirmation dialog; the node is then
tombstoned and every ancestor's total shrinks live.

The treemap is a textbook **squarified** layout (Bruls et al.): children are laid
into rows along the shorter edge, greedily grown to keep cell aspect ratios near
1, recursing into sub-directories down to a minimum cell size. Cells are hit-
tested from a flat array recorded during paint, so hover and click are O(cells).

## Notes / limits

- Symlinks and junctions (reparse points) are skipped, to avoid cycles and
  double-counting.
- Paths and names are handled as ANSI; the size accounting is exact for any
  filename, but a non-ANSI *name* may render with substitution characters.
- The GUI holds one node per file/directory in an arena for the program's
  lifetime (a full drive is a few hundred MB) — it never frees mid-session, which
  is exactly what a one-shot analyzer wants.
