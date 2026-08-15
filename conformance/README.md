# Parlance Conformance Suite

Language-agnostic test vectors for the Parlance runtime. Any implementation — C#, GDScript,
Lua, or another TypeScript port — can run these vectors to prove behavioral parity with the
reference implementation (`editor/core/src/runtime.ts`, which lives in Parlance's private
repository and is not published — these vectors exist precisely so a port never needs it).

> **License: MIT** (see `LICENSE-SPEC`). These files are meant to be copied —
> vendor them into your port and republish freely. The Parlance *editor* is
> licensed separately and is not covered by that grant.

## Files

Counts below drift every time vectors are added, so treat them as indicative and
`jq 'length' tooling/conformance/<file>.json` as authoritative.

| File | Function | Vectors |
|---|---|---|
| `evaluate.json` | `evaluate(condition, state, project)` | 53 |
| `apply_effect.json` | `applyEffect(effect, state, project)` | 27 |
| `resolve_check.json` | `resolveCheck(check, state, rng, defaultDice?, criticals?)` | 18 |
| `step_dialogue.json` | `stepDialogue(dialogue, nodeId, state, project)` | 8 |
| `choose_choice.json` | `chooseChoice(dialogue, nodeId, choiceId, state, project, rng)` | 9 |
| `advance.json` | `advanceNode(dialogue, nodeId, state)` | 9 |
| `resolveCharacterDialogue.json` | `resolveCharacterDialogue(state, character, project)` | 6 |
| `progression.json` | `levelForXp` / `pointsEarned` / `availablePoints` / `investSkillPoint` / `recomputeSkills` | 13 |
| `resolve_quests.json` | `resolveQuests(state, project)` | 6 |
| `rng.json` | mulberry32(seed) output stream — the seeded PRNG ports must reproduce exactly | 6 |

`advance.json` is the one file with a failure case: some vectors carry `expectedError` (a substring
the thrown error must contain) instead of `expected` — see Error cases below. Every other file is
`expected` + deep-equality only.

## Vector format

Each file is a JSON array. Each element is a self-contained test vector with these fields:

```
{
  "fn":          string          // which function to call
  "description": string          // human-readable label

  // Inputs — always present:
  "state":       SerializedGameState
  "dialogue":    Dialogue        // only for stepDialogue / chooseChoice / advanceNode
  "project":     MinimalProject  // any fn that takes one — evaluate, applyEffect,
                                 // stepDialogue, chooseChoice, resolveCharacterDialogue,
                                 // resolveQuests. Omit ⇒ treat as empty.

  // Function-specific inputs:
  "condition":   Condition       // evaluate only
  "effect":      Effect          // applyEffect only
  "check":       Check           // resolveCheck only
  "nodeId":      string          // stepDialogue / chooseChoice / advanceNode
  "choiceId":    string          // chooseChoice only
  "rng":         number | number[]  // resolveCheck and chooseChoice (active checks). Array = one value per die, in order
  "defaultDice": string          // resolveCheck only, optional — project rules.check.dice (absent ⇒ 1d20)

  // Expected output — exactly ONE of these two is present:
  "expected":      varies by fn  // see per-function sections below
  "expectedError": string        // advanceNode only — see Error cases below
}
```

## SerializedGameState

`GameState.inventory` is a `Set<string>` in the reference implementation, which is not
JSON-serializable. Serialized states use a sorted `string[]` instead:

```json
{
  "flags":           { "met_guard": true },
  "reputation":      { "guild": 3 },
  "skills":          { "wit": 5 },
  "counters":        { "stamina": 10 },
  "inventory":       ["key_card"],
  "questStages":     { "quest_main": "stg_enter" }
}
```

**Missing key defaults** (do NOT throw on absent keys — use these values):
- `flags[x]` → `false`
- `reputation[x]` → `0`
- `skills[x]` → `0`
- `counters[x]` → `0`
- `inventory.has(x)` → `false`
- `questStages[x]` → key absent (quest not yet advanced; treat as "not started")
- `relationships[x]` → `0`

**Older serialized states** that lack `questStages` should be treated as `questStages: {}`.

**State comparison:** when comparing output states, sort both `inventory` arrays before
comparing. The reference implementation emits a sorted inventory in `serializeState`.

## MinimalProject

Vectors include a `project` field wherever the function takes one. Which sub-object
matters depends on the call: `factions` for clamping reputation, `quests` for the `quest`
and `questOutcome` conditions and for `resolveQuests`. Treat a missing faction as having
no range limit (raw delta applied without clamping), and a missing quest/outcome as
false:

```json
{ "factions": { "guild": { "id": "guild", "name": "Guild", "summary": "s", "reputationRange": { "min": -10, "max": 10 } } } }
```

## Roll model (`resolveCheck`)

```
spec       = check.dice ? parseDice(check.dice) : (defaultDice ?? 1d20)   // "NdM"
faces      = [floor(rng() * spec.m) + 1, ...]      // spec.n of them, one rng() each, in order
roll       = sum(faces)
skillValue = state.skills[check.skill] ?? 0
total      = roll + skillValue
passed     = total >= check.difficulty
```

Precedence: per-check `check.dice` > the vector's `defaultDice` (the project's
`rules.check.dice`) > `1d20`. A vector's `rng` field is a single float for a one-die
roll, or an array with **one value per die, consumed in order** — the RNG call order is
part of the contract.

**Criticals** (`criticals: true` on a vector): a roll where every face shows the die
minimum ALWAYS fails, and one where every face shows the maximum ALWAYS succeeds,
overriding the total. Judged on individual faces, never the sum — 7 on 2d6 is 1+6 or
3+4, and neither is critical. `CheckResult.critical` is `"success" | "failure"` and is
absent on an ordinary roll.

## Expected output by function

### evaluate
```json
{ "expected": true }   // or false
```

### applyEffect
```json
{ "expected": SerializedGameState }
```
The expected state is the full post-effect state. Fields not touched by the effect are
carried through unchanged from the input state.

### resolveCheck
```json
{ "expected": { "passed": true, "roll": 5, "total": 10, "skillValue": 5 } }
```

### stepDialogue
```json
{ "expected": { "visibleChoiceIds": ["ch_goto", "ch_check"], "onEnterEffectCount": 1 } }
```
`visibleChoiceIds` is the ordered list of choice ids that pass `showIf` filtering.
`onEnterEffectCount` is the count of effects in `node.onEnter` (they are returned but
**not applied** — that is the caller's responsibility).

### chooseChoice
```json
{
  "expected": {
    "nextNodeId": "node_win",
    "newState": SerializedGameState,
    "checkResult": { "passed": true, "roll": 5, "total": 10, "skillValue": 5 }
  }
}
```
`checkResult` is only present for active check vectors. `nextNodeId` is `null` for
terminal choices (no `goto`, no `check`).

### advanceNode
```json
{ "expected": { "nextNodeId": "node_end", "newState": SerializedGameState } }
```
Resolves `node.next` — the choiceless counterpart of `chooseChoice`, for listen-only beats
(ambient chatter, narration) that advance with no player choice. Unlike `chooseChoice`,
**no effects are applied and no check is resolved** — `next` carries neither — so
`newState` always equals the input `state`, byte-for-byte, even when the TARGET node has
`onEnter` effects: those are the caller's responsibility on arrival, exactly as with
`stepDialogue`'s `onEnterEffects` / a `goto` arrival, never `advanceNode`'s own job. Does
not chase further `next` pointers — one call resolves exactly one hop.

**Error cases.** A vector with `expectedError` instead of `expected` means the call must
throw; `expectedError` is a substring the thrown error's message must contain. This is the
one function in the suite with a failure contract — call it only on a node that declares
`next` (the validator's FLOW checks and the client both prevent constructing the call
otherwise); reaching it anyway is a bug upstream, not a `Problem`/result-object case.

### resolveCharacterDialogue
```json
{ "character": Character, "expected": "d_first_meeting" }   // or null
```
Walk `character.dialogues` (the ladder) in order and return the first rung whose `showIf`
passes (absent `showIf` = always). Return `null` if the ladder is empty/absent or nothing
matches. Array order is significant — first match wins. The vector carries the full
`Character` (with its `dialogues` ladder) as an input field.

> **Feed model (contract change).** `activeDialogues` was removed from
> `SerializedGameState`. `set_active_dialogue` now sets the flag
> `active_dialogue__{character}` (see `apply_effect.json`), and dialogue resolution is
> always the ladder via `resolveCharacterDialogue`. Older serialized states that carry an
> `activeDialogues` field should ignore it.

### progression
Each vector carries a `config` (the `progression.json` shape) and dispatches on `fn`:
```json
{ "fn": "levelForXp",       "config": {…}, "xp": 450,              "expected": 3 }
{ "fn": "pointsEarned",     "config": {…}, "xp": 450,              "expected": 3 }
{ "fn": "availablePoints",  "config": {…}, "state": {…},           "expected": 2 }
{ "fn": "investSkillPoint", "config": {…}, "state": {…}, "skillId": "wit", "expected": SerializedGameState }
{ "fn": "recomputeSkills",  "config": {…}, "state": {…},           "expected": SerializedGameState }
```
`investSkillPoint` is a guarded no-op (returns the input state unchanged) when no point is
available or the skill is already at `maxSkill`. `recomputeSkills` sets each skill to
`min(startingSkills + skillPointsSpent, maxSkill)`.

### resolveQuests
```json
{ "project": { "quests": {…} }, "expected": { "state": SerializedGameState, "firings": [{ "quest": "q", "kind": "outcome", "id": "out_x" }] } }
```
Fires condition-gated stage/outcome effects once each (recorded in `questFired`), to a
fixpoint, in deterministic order (quests sorted by id; stages then outcomes in array
order). Items with effects but no condition never fire. `firings` lists what fired, in
order; `expected.state.questFired` is the sorted record.

> **Contract change.** `SerializedGameState` gained `xp` (integer) and `skillPointsSpent`
> (`skillId → integer`). `grant_xp` (see `apply_effect.json`) adds to `xp`. Older serialized
> states lacking these fields are treated as `xp: 0` / `skillPointsSpent: {}`.
> `questFired` (sorted `string[]`) records fired quest items; omitted when empty.

## Running in your language

1. Parse the JSON array.
2. For each vector, deserialize `state` by converting `inventory: string[]` to your
   language's equivalent of `Set<string>`.
3. Call your implementation of the named function with the provided inputs.
4. If the vector carries `expectedError` (advanceNode only): assert the call throws /
   returns an error whose message contains that substring, and stop — there is no output
   state to compare.
5. Otherwise, serialize the output state (if any) back to `{ ..., inventory: string[] }`
   with the inventory array sorted.
6. Assert the result matches `expected` using deep equality.

The reference runner (TypeScript/Vitest) lives in Parlance's private repository; it is
named here only for provenance. These vectors are self-describing precisely so a port
never needs to read it.
