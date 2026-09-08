# ecs_game — a headless ECS asteroids simulation

A bigger, multi-module Gabbro program that exercises the language end to end: local
modules, a struct-of-arrays ECS, generics-free data-oriented systems, enums,
fixed-capacity arrays sized by constants, float math, and a deterministic RNG.

It is **headless and deterministic** — no graphics, no input. A turret at the
centre of the field auto-fires at the nearest asteroid; asteroids drift, bounce
off the walls, and split into fragments when destroyed. It runs 90 ticks,
renders an ASCII snapshot every 30 ticks, and prints a final report.

## Run it

```
gabbro build            # build into ./ecs_game.exe
gabbro build run        # build and run
```

## Layout

```
build.gab            the build script (std.build)
src/
  main.gab           game setup + the tick loop + the report
  vec.gab            Vec2 and 2D math (add/sub/scale/len/dist2/norm)
  components.gab     entity Kind enum + field/world dimensions
  world.gab          the ECS core: struct-of-arrays component store
  systems.gab        movement, lifetime, fire, collisions, spawner
  render.gab         ASCII rasterizer
```

## The ECS

`world.gab` defines a single `World` with **parallel component arrays** indexed by
entity id:

```gabbro
World :: struct {
    pos:    [MAX_ENTITIES]Vec2,
    vel:    [MAX_ENTITIES]Vec2,
    radius: [MAX_ENTITIES]f32,
    hp:     [MAX_ENTITIES]i32,
    kind:   [MAX_ENTITIES]Kind,
    alive:  [MAX_ENTITIES]bool,
    count:  usize,
    // …stats…
}
```

`spawn` allocates an entity (reusing a dead slot when possible) and `kill` frees
one. Each tick the systems sweep the live entities:

- **spawner** — drops a new drifting asteroid on a cadence.
- **fire** — the turret targets the nearest asteroid and emits a bullet.
- **movement** — integrates positions; asteroids bounce, bullets expire off-field.
- **collisions** — O(n²) bullet↔asteroid checks; a destroyed asteroid splits.
- **lifetime** — bullets carry a frame countdown in `hp`.

Everything is plain data + functions over `*World` — the data-oriented style an
ECS encourages, with zero per-tick allocation.
