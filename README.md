# The Mistfall Inn

A small murder mystery, and the public proof that
[Parlance](https://github.com/Orbitope/parlance)'s narrative format is
engine-agnostic.

Parlance stores a game's story as plain JSON — dialogues, conditions, effects,
skill checks, quests, endings. The claim is that any engine can run that JSON
and get *identical* behaviour. This repository is where that claim gets tested
rather than asserted: an independent GDScript runtime, written from the written
contract and the published conformance vectors, with no access to the reference
implementation.

If the vectors pass, "engine-agnostic" is a checkable fact. If they fail, the
claim was marketing.

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

The game exists to prove the runtime survives contact with real authored
content. It is a complete, winnable mystery: three rooms, thirteen dialogues,
three endings, and a murderer you can correctly identify or fail to.

## Try it

Needs [Godot 4](https://godotengine.org/) and nothing else — no build step, no
package manager, no accounts.

```bash
git clone https://github.com/Orbitope/mistfall-inn.git
cd mistfall-inn
godot
```

Run the proof itself:

```bash
godot --headless --script tests/conformance_runner.gd
```

Exit code is 0 only if every implemented family passes. Families not yet ported
are reported as SKIP and never mask a failure — a suite that goes green by not
running is the failure mode the runner is built to avoid.

## Now break it

The most useful thing you can do with this repo is edit it and watch what
happens. Everything below takes one file change and no code.

**Change the story.** `data/dialogues/*.json` is the script. Rewrite a line,
add a choice, point a `goto` somewhere else. Restart the game — that's the whole
edit-test loop. The narrative is CC0, so fork it, remix it, ship it.

**Change the difficulty.** Every skill check declares its own `difficulty`.
Drop `dlg_examine_body`'s from 9 to 5 and watch the odds the UI quotes move
with it — those percentages are computed from the dice distribution, not
hardcoded.

**Change the pacing.** [`data/locations/loc_common_room.json`](data/locations/loc_common_room.json)
has a gate reading
`evidence_count >= 5`. That is what summons the militia and ends the night. Set
it to 2 for a brutally short inquest, or 7 to force exploring every room. The
status bar reads the number out of that gate, so the UI follows automatically.

**Change the dice.** Add `"dice": "2d6"` to any check. The odds display switches
from a flat d20 to a bell curve, correctly, because the probability is derived
from the notation rather than assumed.

**Break the port on purpose.** Flip a comparison in
`addons/parlance/runtime.gd` — change a `>=` to `>` in `_compare` — and re-run
the suite. It should go red immediately and name the vectors that caught you.
If it doesn't, the suite is lying, and that is worth an issue.

**Port it somewhere else.** `conformance/` and `schema/` are MIT and meant to
be copied. They are the whole contract; you never need the reference
implementation. This port is one worked example of using them.

## What is and is not here

**Ported:** `evaluate`, `applyEffect`, `resolveCheck`, `stepDialogue`,
`chooseChoice`, `advanceNode`, `resolveCharacterDialogue`, and the mulberry32
PRNG — everything the mystery needs, including gated choices, active skill
checks, effects, and character dialogue ladders.

**Not ported:** `resolveQuests` and `progression`, reported honestly as SKIP
rather than passed by omission. Neither is needed here: endings hang off
`questOutcome` conditions, which the contract defines as re-evaluating an
outcome's own `reachedWhen` rather than reading a fired-record, so they resolve
without any quest machinery.

**Implemented but NOT vector-covered:** `resolveSpeaker`, `effectiveSpeakerId`,
and `resolvePortrait`. The suite has no family for them, so they come from the
written contract alone with nothing mechanically checking them. They are marked
in-file as the least-trusted code in the port. Treat them accordingly.

**Art:** three 64×64 portraits and nothing else. No backgrounds, no tilesets,
no pixel-art display configuration. The presentation is deliberately plain.

## The story

The Kelder bridge washes out at midnight and strands five travellers at the
Mistfall, the only roof on that stretch of road. Before dawn, Halloran Vane of
the Crown Assessment is dead at the corner table. You are a magistrate's clerk;
the militia arrives at first light and takes whoever you name.

Sera Bragg was about to lose the inn to Vane's assessment. Maud Calloway had
forty pounds of undeclared tin seized at his toll. Aldous Wren was his clerk
until Vane dismissed him without a character. Two of those motives are real,
documented, and wrong.

The full canon, including who did it, is in
[`lore/mistfall.md`](lore/mistfall.md) — the data does not hide it from you.

## Provenance

`data/` and `lore/` are a copy of the Mistfall Inn demo that ships with
Parlance, verified byte-identical to the pinned commit when vendored. One
deliberate divergence since then: the militia threshold was raised from 3 to 5,
in its own commit so the change is visible in `git log data/`.

`conformance/` and `schema/` are a pinned copy of the spec — see
[`conformance/PIN`](conformance/PIN) for the exact ref. Never hand-edit them:
they are generated from and asserted against the reference implementation, so an
edit makes this port chase a ghost.

## Licensing

Mixed, deliberately — see [LICENSE](LICENSE) for the split.

| Part | Licence |
|---|---|
| `addons/parlance/`, `tests/`, `scenes/`, `assets/` | MIT |
| `data/`, `lore/` (the narrative) | CC0 |
| Vendored `conformance/`, `schema/` | MIT, from the Parlance spec |
