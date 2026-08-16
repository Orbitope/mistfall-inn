# The Mistfall Inn

A small murder mystery. One night, one body, three suspects, three endings.

The Kelder bridge washes out at midnight and strands five travellers at the
Mistfall, the only roof on that stretch of road. Before dawn, Halloran Vane of
the Crown Assessment is dead at the corner table. You are a magistrate's clerk;
the militia arrives at first light and takes whoever you name.

Sera Bragg was about to lose the inn to Vane's assessment. Maud Calloway had
forty pounds of undeclared tin seized at his toll. Aldous Wren was his clerk
until Vane dismissed him without a character. Two of those motives are real,
documented, and wrong.

## Play it

Needs [Godot 4](https://godotengine.org/) and nothing else — no build step, no
package manager, no accounts.

```bash
git clone https://github.com/Orbitope/mistfall-inn.git
cd mistfall-inn
godot
```

Examine the body, read the ledger, press the three suspects. Evidence
accumulates; at five pieces the militia arrives and you name someone, or refuse
to. All three endings are reachable, and the correct answer is gettable.

## How it's built

The story is not in the code. It is plain JSON under `data/` — dialogues,
conditions, effects, skill checks, character dialogue ladders, endings — in the
[Parlance](https://github.com/Orbitope/parlance) narrative format, executed by
[parlance-gdscript](https://github.com/Orbitope/parlance-gdscript).

That split is the interesting part, and it makes this repo unusually easy to
tinker with: almost everything you would want to change is a JSON edit, not a
code change.

- `data/` — the entire game. CC0, so fork it, remix it, ship it.
- `lore/mistfall.md` — the canon, including who did it. The data does not hide it.
- `scenes/play.gd` — the presentation layer. Renders rooms and choices; decides
  nothing about the story.
- `addons/parlance/` — the runtime, vendored. See
  [`addons/parlance/VENDORED.md`](addons/parlance/VENDORED.md); fix bugs upstream,
  not here.

## Now break it

Every one of these is a single JSON edit. Restart the game to see it.

**Change the story.** `data/dialogues/*.json` is the script. Rewrite a line, add
a choice, point a `goto` somewhere else.

**Change the difficulty.** Every skill check declares its own `difficulty`. Drop
`dlg_examine_body`'s from 9 to 5 and watch the odds the UI quotes move with it —
those percentages are computed from the dice distribution, not hardcoded.

**Change the pacing.**
[`data/locations/loc_common_room.json`](data/locations/loc_common_room.json) has
a gate reading `evidence_count >= 5`. That is what summons the militia and ends
the night. Set it to 2 for a brutally short inquest, or 7 to force exploring
every room. The status bar reads the number out of that gate, so the UI follows
automatically.

**Change the dice.** Add `"dice": "2d6"` to any check. The odds display switches
from a flat d20 to a bell curve, correctly, because the probability is derived
from the notation rather than assumed.

**Add a suspect.** A character is one JSON file plus a `dialogues` ladder — an
ordered list where the first rung whose `showIf` passes is what they say today.
That ordering is the whole mechanism for making someone respond to what you have
learned.

## Provenance

`data/` and `lore/` are a copy of the Mistfall Inn demo that ships with
Parlance, verified byte-identical when vendored. One deliberate divergence
since: the militia threshold was raised from 3 to 5, in its own commit so it is
visible in `git log data/`.

## Licensing

| Part | Licence |
|---|---|
| `data/`, `lore/` (the narrative) | CC0 |
| `scenes/`, `assets/` (presentation and portraits) | MIT |
| `addons/parlance/` (vendored runtime) | MIT, from parlance-gdscript |

See [LICENSE](LICENSE).
