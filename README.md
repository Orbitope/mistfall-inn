# The Mistfall Inn

A small, text-forward pixel mystery built on [Parlance](https://github.com/Orbitope/parlance) —
and the public proof that its narrative format is engine-agnostic.

Two things live here:

- **`addons/parlance/`** — a GDScript runtime for the Parlance narrative format,
  verified against the vendored conformance vectors in CI. If it passes, "engine-agnostic"
  is a checkable claim rather than a marketing line.
- **The game** — one night, one locked room, three suspects. 320×180, one palette,
  readable at native resolution.

The narrative data is a copy of the Mistfall Inn demo that ships with Parlance. It is
CC0, so it is legal to fork, remix, and learn from.

## Status

Scaffolding. The addon and the conformance runner come before any art.

## Licensing

Mixed, deliberately — see [LICENSE](LICENSE) for the split.

| Part | Licence |
|---|---|
| `addons/parlance/` (the GDScript runtime) | MIT |
| `data/`, `lore/` (the narrative) | CC0 |
| Vendored `conformance/`, `schema/` | MIT, from the Parlance spec |
| Art and audio | per-asset; see `CREDITS.md` |
