# The Mistfall Inn

A GDScript port of the [Parlance](https://github.com/Orbitope/parlance) narrative
runtime, and the public proof that the format is engine-agnostic.

That claim is checkable rather than rhetorical: the port runs the vendored
conformance vectors — the same ones the reference implementation is asserted
against — and the suite's exit code is the evidence.

```
  PASS  mulberry32                     6 vectors
  PASS  evaluate                      53 vectors
  PASS  applyEffect                   27 vectors
  PASS  resolveCheck                  18 vectors
  PASS  stepDialogue                   8 vectors
  PASS  chooseChoice                   9 vectors
  PASS  advanceNode                    9 vectors
  PASS  resolveCharacterDialogue       6 vectors
  SKIP  resolveQuests                  6 vectors — not ported yet
  SKIP  progression                   13 vectors — not ported yet

136 passed, 0 failed, 19 skipped (not yet ported)
```

## Run it

The conformance suite, which is the actual deliverable:

```bash
godot --headless --script tests/conformance_runner.gd
```

Exit code is 0 only if every implemented family passes. Skips are reported and
never mask a failure — a suite that goes green by not running is the failure
mode the runner is built to avoid.

And the mystery itself, which is playable start to finish:

```bash
godot
```

Three rooms, thirteen dialogues, three endings. Examine the body, read the
ledger, press the three suspects, and name someone when the militia arrives at
first light — or name no one. All three endings are reachable.

## What is and is not here

**Ported:** `evaluate`, `applyEffect`, `resolveCheck`, `stepDialogue`,
`chooseChoice`, `advanceNode`, `resolveCharacterDialogue`, and the mulberry32
PRNG — everything the mystery needs, including gated choices, active skill
checks, effects, and character dialogue ladders.

**Not ported:** `resolveQuests` and `progression`. They are reported as SKIP,
honestly, rather than passed by omission. Neither is needed: the endings hang
off `questOutcome` conditions, which the contract defines as re-evaluating an
outcome's own `reachedWhen` rather than reading a fired-record — so they
resolve correctly without any quest machinery.

**Uncovered by the vectors:** `resolveSpeaker`, `effectiveSpeakerId`, and
`resolvePortrait`. The suite has no family for them, so they are implemented
from the written contract alone with nothing mechanically checking them.

**Art:** three 64×64 character portraits, and nothing else. No backgrounds, no
tilesets, no pixel-art display configuration. The presentation is deliberately
plain — the runtime is the deliverable, and the game is what proves it runs.

## The story, for the curious

The Kelder bridge washes out at midnight and strands five travellers at the
Mistfall, the only roof on that stretch of road. Before dawn, Halloran Vane of
the Crown Assessment is dead at the corner table. You are a magistrate's clerk;
the militia arrives at first light and takes whoever you name.

Sera Bragg was about to lose the inn to Vane's assessment. Maud Calloway had
forty pounds of undeclared tin seized at his toll. Aldous Wren was his clerk
until Vane dismissed him without a character. Two of those motives are real,
documented, and wrong.

The full canon is in [`lore/mistfall.md`](lore/mistfall.md) — including who did
it, which the data does not hide from you.

## Provenance

The narrative data in `data/` and `lore/` is a copy of the Mistfall Inn demo
that ships with Parlance. The vectors in `conformance/` and schemas in `schema/`
are a pinned copy of the spec — see [`conformance/PIN`](conformance/PIN) for the
exact ref, and never hand-edit them: they are generated from and asserted
against the reference implementation, so an edit makes this port chase a ghost.

## Licensing

Mixed, deliberately — see [LICENSE](LICENSE) for the split.

| Part | Licence |
|---|---|
| `addons/parlance/`, `tests/`, `scenes/` | MIT |
| `data/`, `lore/` (the narrative) | CC0 |
| Vendored `conformance/`, `schema/` | MIT, from the Parlance spec |
| Art and audio | per-asset; see `CREDITS.md` |
