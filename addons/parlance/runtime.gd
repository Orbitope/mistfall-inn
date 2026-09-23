class_name ParlanceRuntime
extends RefCounted

## The Parlance runtime, ported to GDScript.
##
## Ports every conformance family: evaluate, applyEffect, resolveCheck,
## stepDialogue, chooseChoice, advanceNode, resolveCharacterDialogue,
## nextContinuations, resolveQuests and progression.
##
## `project` is a plain Dictionary in the vectors' MinimalProject shape
## (`{"factions": {...}, "quests": {...}}`). Missing sub-objects are legal and
## mean "no data": an unknown faction applies its delta unclamped, an unknown
## quest is false for every op. Nothing here throws on missing project data.
##
## ERRORS. GDScript has no exceptions, so the one family with a throw contract
## (`advance_node`) returns `{"error": "..."}` instead. Callers must check for
## that key — see the function's own note. `resolve_check` (and so
## `choose_choice`) does the same for a check that declares modifiers but is
## given no project. Every other entry point is total.

const Rng := preload("res://addons/parlance/rng.gd")
const State := preload("res://addons/parlance/state.gd")
const Interp := preload("res://addons/parlance/interpolate.gd")


# ---------------------------------------------------------------- evaluate --


## Evaluates a condition against state. Total: never throws, never mutates.
static func evaluate(condition, state: State, project := {}) -> bool:
	return _evaluate(condition, state, project, {})


## `visiting` carries the questOutcome reference cycle guard. An outcome whose
## `reachedWhen` leads back to itself is false rather than a stack overflow —
## the suite has a vector for exactly that.
## How SPECIFIC a condition is — the "most specific offer wins" tiebreak in
## resolve_character_dialogue. Lives beside evaluate because the reference does.
##
##   absent (a fallback offer) -> 0      any leaf -> 1
##   all -> SUM of members               any -> MIN of members (0 if empty)
##   not -> its operand's
##
## `any` is MIN, not a clause count: any(a, b, c) is only as specific as its
## weakest branch, and a count would rank it above `a` alone. Total and pure.
static func condition_specificity(condition) -> int:
	if not condition is Dictionary:
		return 0
	match condition.get("type", ""):
		"all":
			var total := 0
			for c in condition.get("of", []):
				total += condition_specificity(c)
			return total
		"any":
			var members: Array = condition.get("of", [])
			if members.is_empty():
				return 0
			var lowest := condition_specificity(members[0])
			for c in members:
				lowest = mini(lowest, condition_specificity(c))
			return lowest
		"not":
			return condition_specificity(condition.get("of", null))
		_:
			return 1


static func _evaluate(condition, state: State, project: Dictionary, visiting: Dictionary) -> bool:
	if not condition is Dictionary:
		return false

	match condition.get("type", ""):
		"flag":
			# Exact boolean equality, not truthiness: `value: false` must match
			# an unset flag, which a truthiness test would get backwards.
			return bool(state.flags.get(condition.get("flag", ""), false)) == bool(condition.get("value", true))

		"reputation":
			return _compare(state.reputation.get(condition.get("faction", ""), 0), condition.get("op", "=="), condition.get("value", 0))

		"skill":
			return _compare(state.skills.get(condition.get("skill", ""), 0), condition.get("op", "=="), condition.get("value", 0))

		"counter":
			return _compare(state.counters.get(condition.get("counter", ""), 0), condition.get("op", "=="), condition.get("value", 0))

		"relationship":
			return _compare(state.relationships.get(condition.get("character", ""), 0), condition.get("op", "=="), condition.get("value", 0))

		"item":
			return state.inventory.has(condition.get("item", "")) == bool(condition.get("has", true))

		"quest":
			return _evaluate_quest(condition, state, project)

		"questOutcome":
			return _evaluate_quest_outcome(condition, state, project, visiting)

		"all":
			# Left-to-right short-circuit, and an empty `of` is vacuously true.
			for sub in condition.get("of", []):
				if not _evaluate(sub, state, project, visiting):
					return false
			return true

		"any":
			for sub in condition.get("of", []):
				if _evaluate(sub, state, project, visiting):
					return true
			return false

		"not":
			return not _evaluate(condition.get("of", null), state, project, visiting)

	return false


## Quest stage comparison is by ORDER, not id equality, so `>= stg_x` means
## "at or past x".
##
## Three degradations, all of them deliberate and all vector-covered:
##   * an unadvanced quest sits BEFORE every stage (order -1), so `< stg_first`
##     passes and `>=`/`==` fail — this is what "has not started yet" means;
##   * a current stage the quest no longer defines degrades to unadvanced,
##     rather than erroring, so deleting a stage cannot brick a save;
##   * an unknown quest, or an unknown TARGET stage, is false for every op.
static func _evaluate_quest(condition: Dictionary, state: State, project: Dictionary) -> bool:
	var quest = project.get("quests", {}).get(condition.get("quest", ""), null)
	if not quest is Dictionary:
		return false

	var target_order := _stage_order(quest, condition.get("stage", ""))
	if target_order == null:
		return false

	var current_order := -1
	if state.quest_stages.has(condition.get("quest", "")):
		var found := _stage_order(quest, state.quest_stages[condition.get("quest", "")])
		if found != null:
			current_order = found

	return _compare(current_order, condition.get("op", "=="), target_order)


## The stage's declared `order` field (required by the schema), NOT its array
## index — authoring order and declared order are allowed to differ.
## Returns null when the quest does not define that stage.
static func _stage_order(quest: Dictionary, stage_id) -> Variant:
	for stage in quest.get("stages", []):
		if stage is Dictionary and stage.get("id", null) == stage_id:
			return int(stage.get("order", 0))
	return null


## True when the named outcome's own `reachedWhen` evaluates true right now.
##
## Deliberately NOT a `questFired` lookup: quest resolution only records items
## carrying effects, so a fired-record read would be permanently false for
## every effect-free outcome. Re-evaluating also keeps this independent of
## whether the host has called resolveQuests yet.
static func _evaluate_quest_outcome(condition: Dictionary, state: State, project: Dictionary, visiting: Dictionary) -> bool:
	var quest_id = condition.get("quest", "")
	var outcome_id = condition.get("outcome", "")

	var key := "%s/%s" % [quest_id, outcome_id]
	if visiting.has(key):
		return false  # Reference cycle. Terminate false rather than recurse.

	var quest = project.get("quests", {}).get(quest_id, null)
	if not quest is Dictionary:
		return false

	for outcome in quest.get("outcomes", []):
		if not (outcome is Dictionary and outcome.get("id", null) == outcome_id):
			continue
		# An outcome with no reachedWhen is never reached.
		if not outcome.has("reachedWhen"):
			return false
		var guard := visiting.duplicate()
		guard[key] = true
		return _evaluate(outcome["reachedWhen"], state, project, guard)

	return false


static func _compare(left, op, right) -> bool:
	var a := float(left)
	var b := float(right)
	match op:
		">=": return a >= b
		"<=": return a <= b
		"==": return a == b
		">": return a > b
		"<": return a < b
	return false


# ------------------------------------------------------------- applyEffect --


## Applies one effect and returns a NEW state; the input is never mutated.
static func apply_effect(effect, state: State, project := {}) -> State:
	# Typed explicitly: `copy()` returns Variant so that state.gd needs no
	# reference to its own global class_name, which does not resolve in a
	# headless `--script` run.
	var next: State = state.copy()
	if not effect is Dictionary:
		return next

	match effect.get("type", ""):
		"set_flag":
			next.flags[effect.get("flag", "")] = bool(effect.get("value", true))

		"adjust_reputation":
			var faction_id = effect.get("faction", "")
			var raw := float(next.reputation.get(faction_id, 0)) + float(effect.get("delta", 0))
			# Clamped to the faction's declared range — but ONLY if the project
			# knows the faction. An unknown faction applies the raw delta.
			var faction = project.get("factions", {}).get(faction_id, null)
			if faction is Dictionary and faction.get("reputationRange", null) is Dictionary:
				var r: Dictionary = faction["reputationRange"]
				raw = clampf(raw, float(r.get("min", -INF)), float(r.get("max", INF)))
			next.reputation[faction_id] = raw

		"adjust_counter":
			# Unbounded by contract — counters are not clamped.
			next.counters[effect.get("counter", "")] = float(next.counters.get(effect.get("counter", ""), 0)) + float(effect.get("delta", 0))

		"adjust_relationship":
			next.relationships[effect.get("character", "")] = float(next.relationships.get(effect.get("character", ""), 0)) + float(effect.get("delta", 0))

		"give_item":
			next.inventory[effect.get("item", "")] = true

		"take_item":
			next.inventory.erase(effect.get("item", ""))  # no-op when not held

		"advance_quest":
			# Records the stage id and nothing else. Evaluating completeWhen or
			# outcomes is the caller's job, not the runtime's.
			next.quest_stages[effect.get("quest", "")] = effect.get("toStage", "")

		"grant_xp":
			next.xp += float(effect.get("amount", 0))

		"set_active_dialogue":
			# The feed model: a flag, not a separate map. The forced dialogue
			# carries a tier-1 offer gated on it, and `dialogue` is metadata
			# for tooling. Clear it with an ordinary set_flag false.
			next.flags["active_dialogue__" + str(effect.get("character", ""))] = true

		"play_cutscene":
			# Records the request only — the runtime never plays anything, and
			# never clears this either. Last write wins.
			next.pending_cutscene = effect.get("cutscene", "")

		"set_text":
			next.texts[effect.get("variable", "")] = effect.get("value", "")

	return next


## Threads state left-to-right through each effect.
static func apply_effects(effects, state: State, project := {}) -> State:
	var next := state
	for effect in effects if effects != null else []:
		next = apply_effect(effect, next, project)
	return next


# ------------------------------------------------------------ resolveCheck --


## Rolls an active check.
##
## RNG CALL ORDER IS PART OF THE CONTRACT: one `rng()` call per die, left to
## right. A port that rolls 2d6 with one call and doubles it produces plausible
## numbers and a different story.
##
## `default_dice` is the project's `rules.check.dice`. Precedence is
## check.dice > default_dice > 1d20.
##
## MODIFIERS (contract 0.14.0): total = roll + skill + check_bonus. Evaluating a
## modifier's `when` needs the project (quest conditions read stage order), so
## a check that declares modifiers and is given no project returns
## `{"error": ...}` — the reference throws there rather than read those
## conditions as silently false. `bonus` and `appliedModifiers` appear in the
## result ONLY when the check declares a modifier, so an unmodified check's
## result is byte-identical to the pre-0.14 one.
static func resolve_check(check: Dictionary, state: State, rng: Callable, default_dice = null, criticals := false, project = null) -> Dictionary:
	var has_modifiers: bool = check.get("modifiers", null) is Array and not check["modifiers"].is_empty()
	if has_modifiers and not project is Dictionary:
		return {"error": "resolve_check: check has modifiers; pass project"}

	var notation := str(check.get("dice", default_dice if default_dice != null else "1d20"))
	var spec := parse_dice(notation)

	var faces: Array[int] = []
	for _i in spec.n:
		faces.append(int(floor(float(rng.call()) * spec.m)) + 1)

	var roll := 0
	for face in faces:
		roll += face

	var skill_value := float(state.skills.get(check.get("skill", ""), 0))
	var mod := check_bonus(check, state, project) if has_modifiers else {}
	var total := float(roll) + skill_value + float(mod.get("bonus", 0))
	var passed := total >= float(check.get("difficulty", 0))

	var result := {
		"passed": passed,
		"roll": roll,
		"total": total,
		"skillValue": skill_value,
		"dice": "%dd%d" % [spec.n, spec.m],
	}
	if has_modifiers:
		result["bonus"] = mod["bonus"]
		result["appliedModifiers"] = mod["appliedModifiers"]

	# Criticals are judged on individual FACES, never the sum: 7 on 2d6 is 1+6
	# or 3+4, and neither is critical. Default off — enabling changes every
	# check outcome, so it is a per-project opt-in.
	if criticals:
		var all_max := true
		var all_min := true
		for face in faces:
			if face != spec.m:
				all_max = false
			if face != 1:
				all_min = false
		if all_max:
			result["passed"] = true
			result["critical"] = "success"
		elif all_min:
			result["passed"] = false
			result["critical"] = "failure"

	return result


## Σ of every modifier's `bonus` whose `when` holds, plus the indices that
## contributed, in array order: `{"bonus": float, "appliedModifiers": [int]}`.
## THE one place modifiers are summed, so the roll and the passive reveal can
## never disagree. Total and pure.
static func check_bonus(check: Dictionary, state: State, project = {}) -> Dictionary:
	var proj: Dictionary = project if project is Dictionary else {}
	var bonus := 0.0
	var applied: Array = []
	var mods = check.get("modifiers", null)
	if mods is Array:
		for i in mods.size():
			var m = mods[i]
			if m is Dictionary and evaluate(m.get("when", null), state, proj):
				bonus += float(m.get("bonus", 0))
				applied.append(i)
	return {"bonus": bonus, "appliedModifiers": applied}


## Whether a PASSIVE check reveals its choice: skill + Σbonus >= difficulty.
## Passive checks do not roll; this is the threshold an engine applies to show
## or hide the option, so a modifier means the same thing in both modes.
static func passive_check_passes(check: Dictionary, state: State, project := {}) -> bool:
	var skill_value := float(state.skills.get(check.get("skill", ""), 0))
	return skill_value + float(check_bonus(check, state, project)["bonus"]) >= float(check.get("difficulty", 0))


## "NdM" -> {n, m}. Falls back to 1d20 on anything unparseable rather than
## throwing; the validator is what tells an author their notation is wrong.
static func parse_dice(notation: String) -> Dictionary:
	var parts := notation.strip_edges().to_lower().split("d")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		var n := int(parts[0])
		var m := int(parts[1])
		if n >= 1 and m >= 2:
			return {"n": n, "m": m}
	return {"n": 1, "m": 20}


# ----------------------------------------------------------- stepDialogue --


## Prepares a node for display: filters choices by `showIf` and interpolates
## player-facing text.
##
## Returns `{"node", "visibleChoices", "onEnterEffects", "error"}`.
##
## CALLER RESPONSIBILITY: `onEnterEffects` are RETURNED, NOT APPLIED. The
## caller decides when they fire (on first arrival; not on replay). Applying
## them here would double-fire every effect on a rewind.
static func step_dialogue(dialogue: Dictionary, node_id: String, state: State, project := {}) -> Dictionary:
	var node: Variant = find_node(dialogue, node_id)
	if node == null:
		return {"error": "node '%s' does not exist in dialogue '%s'" % [node_id, dialogue.get("id", "?")]}

	# Node-level showIf skip walk (contract 0.11.0): stepping onto a gated node
	# whose gate fails resolves to the node the player actually sees — the same
	# skip advance_node performs. A ring of failing gates is COND-invalid and is
	# reported rather than looped.
	var seen := {}
	while node.has("showIf") and not evaluate(node["showIf"], state, project):
		var here := str(node.get("id", node_id))
		if seen.has(here):
			return {"error": "Cycle among conditional nodes: resolution cannot escape"}
		seen[here] = true
		if not node.has("next"):
			return {"error": "conditional node '%s' has no 'next' to skip to" % here}
		var next_id := str(node["next"])
		var next_node: Variant = find_node(dialogue, next_id)
		if next_node == null:
			return {"error": "next target '%s' does not exist in dialogue '%s'" % [next_id, dialogue.get("id", "?")]}
		node = next_node

	var visible: Array = []
	for choice in node.get("choices", []):
		if not choice is Dictionary:
			continue
		if choice.has("showIf") and not evaluate(choice["showIf"], state, project):
			continue
		# Copy only when a placeholder was actually substituted, so callers
		# comparing node identity to detect edits keep working.
		var text := str(choice.get("text", ""))
		var rendered := Interp.interpolate(text, state)
		if rendered == text:
			visible.append(choice)
		else:
			var c: Dictionary = choice.duplicate(true)
			c["text"] = rendered
			visible.append(c)

	var out_node := node
	var node_text := str(node.get("text", ""))
	var rendered_text := Interp.interpolate(node_text, state)
	if rendered_text != node_text:
		out_node = node.duplicate(true)
		out_node["text"] = rendered_text

	return {
		"node": out_node,
		"visibleChoices": visible,
		"onEnterEffects": node.get("onEnter", []),
	}


# ----------------------------------------------------------- chooseChoice --


## Applies a choice's effects, resolves its check if active, and reports where
## to go next.
##
## Returns `{"nextNodeId", "newState", "checkResult"?, "error"?}`.
## `nextNodeId` is null for a terminal choice (no goto, no check).
## `checkResult` is present ONLY for an active check — a passive check is a
## plain goto and never rolls.
static func choose_choice(dialogue: Dictionary, node_id: String, choice_id: String, state: State, project := {}, rng := Callable()) -> Dictionary:
	var node: Variant = find_node(dialogue, node_id)
	if node == null:
		return {"error": "node '%s' does not exist in dialogue '%s'" % [node_id, dialogue.get("id", "?")]}

	var choice = null
	for c in node.get("choices", []):
		if c is Dictionary and c.get("id", null) == choice_id:
			choice = c
			break
	if choice == null:
		return {"error": "choice '%s' does not exist on node '%s'" % [choice_id, node_id]}

	var next_state := apply_effects(choice.get("effects", []), state, project)

	var check = choice.get("check", null)
	if check is Dictionary and check.get("mode", "") == "active":
		var rules: Dictionary = project.get("rules", {}).get("check", {}) if project.get("rules", null) is Dictionary else {}
		var result := resolve_check(check, next_state, rng, rules.get("dice", null), bool(rules.get("criticals", false)), project)
		if result.has("error"):
			return result
		return {
			"nextNodeId": check.get("onSuccess", null) if result["passed"] else check.get("onFailure", null),
			"newState": next_state,
			"checkResult": result,
		}

	# Passive checks fall through here deliberately: they are a plain goto with
	# a reveal effect, and never produce a checkResult.
	return {
		"nextNodeId": choice.get("goto", null),
		"newState": next_state,
	}


# ------------------------------------------------------------ advanceNode --


## Resolves `node.next` — the choiceless counterpart of choose_choice, for
## listen-only beats that advance with no player choice.
##
## THIS IS THE ONE FUNCTION WITH A FAILURE CONTRACT. The reference throws;
## GDScript has no exceptions, so this returns `{"error": "..."}` and the
## conformance runner treats that as the throw. Callers MUST check for it.
## Silence here would hide an upstream bug: the validator's FLOW checks and the
## client both prevent constructing this call on a node with no `next`.
##
## No effects are applied and no check is resolved — `next` carries neither, so
## `newState` is the input state unchanged. Effects live on the TARGET's
## `onEnter` and are the caller's job on arrival, exactly as for a goto. That
## is what makes an advance-arrival and a goto-arrival identical.
##
## Resolves exactly ONE hop. A runtime that auto-chased `next` would collapse a
## whole ambient run into one uninterruptible jump.
static func advance_node(dialogue: Dictionary, node_id: String, state: State) -> Dictionary:
	var node: Variant = find_node(dialogue, node_id)
	if node == null:
		return {"error": "node '%s' does not exist in dialogue '%s'" % [node_id, dialogue.get("id", "?")]}

	if not node.has("next"):
		return {"error": "node '%s' has no 'next' to advance from" % node_id}

	var target_id := str(node["next"])

	# Node-level showIf skip walk (contract 0.11.0): cross gated nodes whose gate
	# fails, following each one's `next`, until a shown node is reached. A ring of
	# failing gates is COND-invalid data and is reported, not looped. onEnter does
	# not fire here — advance is navigation, exactly as the ungated path is.
	var visited := {}
	while true:
		var target_node: Variant = find_node(dialogue, target_id)
		if target_node == null:
			return {"error": "next target '%s' does not exist in dialogue '%s'" % [target_id, dialogue.get("id", "?")]}
		if not target_node.has("showIf"):
			break
		if evaluate(target_node["showIf"], state, {}):
			break
		if visited.has(target_id):
			return {"error": "Cycle among conditional nodes: resolution cannot escape"}
		visited[target_id] = true
		if not target_node.has("next"):
			return {"error": "conditional node '%s' has no 'next' to skip to" % target_id}
		target_id = str(target_node["next"])

	return {"nextNodeId": target_id, "newState": state}


# ----------------------------------------- resolveCharacterDialogue (offers) --


## Which dialogue this character offers right now, or null (contract 0.14.0).
##
## A dialogue opts in by carrying an `offer` object — its PRESENCE is the
## opt-in, so `"offer": {}` is a fallback and a dialogue with no `offer` is
## never a candidate. It is offered by `offer.character ?? speakerId`. Among
## this character's offers, those whose `offer.when` passes (absent = always)
## are eligible, minus — when `visited` is given — any non-`replayable` one
## already seen. The winner is the most salient eligible offer:
##
##   1. priority tier  descending  (offer.priority, default 0)
##   2. specificity    descending  (condition_specificity(offer.when))
##   3. id             ascending   (ordinal code-unit compare, NOT locale)
##
## There is no array order anywhere: which file a dialogue lives in, or where
## it sits in `project.dialogues`, never changes the answer.
##
## The feed model: there is no `activeDialogues` map. `set_active_dialogue`
## sets the flag `active_dialogue__{character}`, and the forced dialogue carries
## a tier-1 offer gated on it, which out-ranks every tier-0 offer.
##
## `visited` is an Array (or Dictionary keyed by id) of dialogue ids the host
## has shown; omit it for the pure state answer.
static func resolve_character_dialogue(state: State, character: Dictionary, project := {}, visited = null) -> Variant:
	var character_id = character.get("id", null)
	var dialogues = project.get("dialogues", {})
	if not dialogues is Dictionary:
		return null

	var best = null
	for dialogue in dialogues.values():
		if not dialogue is Dictionary:
			continue
		# `is Dictionary`, not `has`: hand-edited data can carry `offer: null`,
		# which the validator reports but the runtime must survive.
		var offer = dialogue.get("offer", null)
		if not offer is Dictionary:
			continue
		if offer.get("character", dialogue.get("speakerId", null)) != character_id:
			continue
		if offer.has("when") and not evaluate(offer["when"], state, project):
			continue
		if visited != null and dialogue.get("replayable", false) != true and _visited_has(visited, dialogue.get("id", null)):
			continue
		if best == null or _better_offer(dialogue, best):
			best = dialogue

	return best.get("id", null) if best != null else null


## True if offer `a` outranks `b`: higher tier, then higher specificity, then
## the lower id. GDScript's String `<` compares code points, which orders
## exactly like the reference's UTF-16 compare for every id outside the astral
## planes — and ids are ASCII by schema.
static func _better_offer(a: Dictionary, b: Dictionary) -> bool:
	var pa := int(a["offer"].get("priority", 0))
	var pb := int(b["offer"].get("priority", 0))
	if pa != pb:
		return pa > pb
	var sa := condition_specificity(a["offer"].get("when", null))
	var sb := condition_specificity(b["offer"].get("when", null))
	if sa != sb:
		return sa > sb
	return str(a.get("id", "")) < str(b.get("id", ""))


static func _visited_has(visited, id) -> bool:
	if visited is Dictionary:
		return visited.has(id)
	if visited is Array:
		return visited.has(id)
	return false


# ------------------------------------------------------ nextContinuations --


## The flag a `set_active_dialogue` effect for `character_id` sets.
static func active_dialogue_flag(character_id: String) -> String:
	return "active_dialogue__" + character_id


## Clears a character's `active_dialogue__` flag (sets it false) so its forced
## offer stops winning. Call once a forced dialogue has been consumed.
static func clear_active_dialogue(character_id: String, state: State) -> State:
	var next: State = state.copy()
	next.flags[active_dialogue_flag(character_id)] = false
	return next


## Clears the queued cutscene once the host has played it.
static func clear_pending_cutscene(state: State) -> State:
	var next: State = state.copy()
	next.pending_cutscene = null
	return next


## What to offer the player when the current scene ends (the feed model).
##
## Returns an Array of
##   {"kind": "cutscene", "cutscene": {...}}
##   {"kind": "dialogue", "characterId": id, "dialogue": {...}, "queued": bool}
##
## A pending cutscene always comes first. Then FORCED routing: every character
## whose `active_dialogue__` flag is set and whose winning offer actually READS
## that flag (a top-level `flag = true` conjunct) is queued, ignoring the
## visited set. If any character is forced, only those are returned. Otherwise
## DISCOVERY: each character's best eligible offer, with the visited filter.
## The current dialogue is always excluded; results are de-duplicated by id.
##
## A routed character whose best offer is an ORDINARY one is not forced: it is
## not queued, does not bypass the visited set, and its flag stays set until
## the forced offer can win.
static func next_continuations(state: State, project: Dictionary, visited, current_dialogue_id: String) -> Array:
	var seen := {current_dialogue_id: true}
	var dialogues: Dictionary = project.get("dialogues", {}) if project.get("dialogues", null) is Dictionary else {}
	var characters: Dictionary = project.get("characters", {}) if project.get("characters", null) is Dictionary else {}

	var pending: Array = []
	if state.pending_cutscene != null:
		var cutscenes = project.get("cutscenes", {})
		if cutscenes is Dictionary and cutscenes.get(state.pending_cutscene, null) is Dictionary:
			pending.append({"kind": "cutscene", "cutscene": cutscenes[state.pending_cutscene]})

	var forced: Array = []
	for character in characters.values():
		if not character is Dictionary:
			continue
		var flag := active_dialogue_flag(str(character.get("id", "")))
		if state.flags.get(flag, false) != true:
			continue
		var resolved = resolve_character_dialogue(state, character, project)
		if resolved == null or not dialogues.get(resolved, null) is Dictionary:
			continue
		var dialogue: Dictionary = dialogues[resolved]
		if not _condition_reads_flag(dialogue.get("offer", {}).get("when", null), flag):
			continue
		if not seen.has(resolved):
			seen[resolved] = true
			forced.append({"kind": "dialogue", "characterId": character.get("id"), "dialogue": dialogue, "queued": true})
	if not forced.is_empty():
		return pending + forced

	var discovered: Array = []
	for character in characters.values():
		if not character is Dictionary:
			continue
		var resolved = resolve_character_dialogue(state, character, project, visited if visited != null else [])
		if resolved == null or not dialogues.get(resolved, null) is Dictionary:
			continue
		if not seen.has(resolved):
			seen[resolved] = true
			discovered.append({"kind": "dialogue", "characterId": character.get("id"), "dialogue": dialogues[resolved], "queued": false})
	return pending + discovered


## Does this gate REQUIRE `flag` to be true — a top-level conjunct
## `flag = true`, with `all` flattened? The test for a forced offer.
static func _condition_reads_flag(condition, flag: String) -> bool:
	if not condition is Dictionary:
		return false
	if condition.get("type", "") == "all":
		for c in condition.get("of", []):
			if _condition_reads_flag(c, flag):
				return true
		return false
	return condition.get("type", "") == "flag" and condition.get("flag", null) == flag and condition.get("value", null) == true


# ---------------------------------------------------------- resolveQuests --


## The questFired record key for a stage or outcome.
static func quest_fired_key(quest_id: String, kind: String, id: String) -> String:
	return "%s/%s/%s" % [quest_id, kind, id]


## Fires quest stage `onComplete` and outcome `effects` whose condition
## (`completeWhen` / `reachedWhen`) holds, once each per playthrough.
##
## Returns {"state": State, "firings": [{quest, kind, id, effects}]}. With no
## firings the input state is returned as is.
##
##   - An item fires only if it HAS effects AND a condition, the condition is
##     true, and its key is not already in quest_fired. Effects with no
##     condition never auto-fire.
##   - Runs to a fixpoint: one firing's effects may satisfy another's
##     condition. Terminates because each item fires at most once.
##   - Deterministic order: quests by id, then stages, then outcomes, each in
##     array order.
##   - Never writes quest_stages; advancing a stage stays the author's effect.
static func resolve_quests(state: State, project: Dictionary) -> Dictionary:
	var quests: Dictionary = project.get("quests", {}) if project.get("quests", null) is Dictionary else {}
	var quest_ids := quests.keys()
	quest_ids.sort()

	var current := state
	var firings: Array = []
	var changed := true
	while changed:
		changed = false
		for qid in quest_ids:
			var quest = quests[qid]
			if not quest is Dictionary:
				continue
			for stage in quest.get("stages", []):
				if stage is Dictionary:
					var r := _try_fire(current, project, str(qid), "stage", stage, "completeWhen", "onComplete", firings)
					if r != null:
						current = r
						changed = true
			for outcome in quest.get("outcomes", []):
				if outcome is Dictionary:
					var r := _try_fire(current, project, str(qid), "outcome", outcome, "reachedWhen", "effects", firings)
					if r != null:
						current = r
						changed = true

	return {"state": current, "firings": firings}


## One item's firing attempt: the new state if it fired, else null.
static func _try_fire(state: State, project: Dictionary, quest_id: String, kind: String, item: Dictionary, when_key: String, effects_key: String, firings: Array) -> State:
	var effects = item.get(effects_key, null)
	if not (effects is Array and not effects.is_empty()):
		return null
	if not item.has(when_key):
		return null
	var key := quest_fired_key(quest_id, kind, str(item.get("id", "")))
	if state.quest_fired.has(key):
		return null
	if not evaluate(item[when_key], state, project):
		return null
	# `effects` is non-empty, so apply_effects has already copied.
	var next := apply_effects(effects, state, project)
	next.quest_fired[key] = true
	firings.append({"quest": quest_id, "kind": kind, "id": item.get("id", ""), "effects": effects})
	return next


# ------------------------------------------------------------ progression --
#
# `xp` is total-earned and monotonic; levels and points are DERIVED from it,
# never stored, so they cannot desync. `config` is progression.json. `skills`
# is the optional skills registry (id -> skill), for per-skill `max` caps.


## Highest threshold index whose value is <= xp.
static func level_for_xp(xp: float, config: Dictionary) -> int:
	var level := 0
	var thresholds: Array = config.get("xpThresholds", [])
	for i in thresholds.size():
		if xp >= float(thresholds[i]):
			level = i
		else:
			break
	return level


## Total skill points ever granted at this xp: level x pointsPerLevel.
static func points_earned(xp: float, config: Dictionary) -> float:
	return float(level_for_xp(xp, config)) * float(config.get("pointsPerLevel", 0))


## A skill's ceiling: its own `max` if the registry sets one, else maxSkill.
static func skill_cap(skill_id: String, config: Dictionary, skills := {}) -> float:
	var skill = skills.get(skill_id, null)
	if skill is Dictionary and skill.has("max"):
		return float(skill["max"])
	return float(config.get("maxSkill", 0))


## Preset loadout + points invested, clamped to the skill's ceiling.
static func effective_skill(skill_id: String, state: State, config: Dictionary, skills := {}) -> float:
	var preset := float(config.get("startingSkills", {}).get(skill_id, 0))
	var invested := float(state.skill_points_spent.get(skill_id, 0))
	return minf(preset + invested, skill_cap(skill_id, config, skills))


## Unspent points: earned minus everything invested. Derived, never stored.
static func available_points(state: State, config: Dictionary) -> float:
	var spent := 0.0
	for v in state.skill_points_spent.values():
		spent += float(v)
	return points_earned(state.xp, config) - spent


## skills = effective_skill for every preset or invested skill. Skills outside
## progression are left alone. Call on load and after any invest.
static func recompute_skills(state: State, config: Dictionary, skills := {}) -> State:
	var next: State = state.copy()
	var ids := {}
	for id in config.get("startingSkills", {}).keys():
		ids[id] = true
	for id in state.skill_points_spent.keys():
		ids[id] = true
	for id in ids.keys():
		next.skills[id] = effective_skill(str(id), state, config, skills)
	return next


## Spends one point on `skill_id`. A player action (level-up UI), not an
## effect. A no-op unless a point is available AND the skill is below its
## ceiling, so a point is never wasted on a capped skill.
static func invest_skill_point(state: State, skill_id: String, config: Dictionary, skills := {}) -> State:
	if available_points(state, config) <= 0:
		return state
	if effective_skill(skill_id, state, config, skills) >= skill_cap(skill_id, config, skills):
		return state
	var next: State = state.copy()
	next.skill_points_spent[skill_id] = float(next.skill_points_spent.get(skill_id, 0)) + 1.0
	return recompute_skills(next, config, skills)


# ------------------------------------------------------ speaker / portrait --
#
# NO CONFORMANCE COVERAGE. The vector suite has no family for these three, so
# unlike everything above they are implemented from the written contract alone
# and nothing mechanically checks them. Treat them as the least-trusted code in
# this file.


## `node.speakerId ?? dialogue.speakerId`. Named so nothing else re-implements
## this one `??`. Returns null when neither sets a speaker.
static func effective_speaker_id(dialogue: Dictionary, node: Dictionary) -> Variant:
	if node.has("speakerId"):
		return node["speakerId"]
	if dialogue.has("speakerId"):
		return dialogue["speakerId"]
	return null


## Resolves the effective speaker id to a concrete entity:
##   {"kind": "narration"} | {"kind": "character", "character": {...}}
##                         | {"kind": "skill", "skill": {...}}
##
## A dialogue-level speakerId is character-only (it doubles as the default
## `offer.character` for offer resolution); only the NODE level may name a skill — that is the
## skill-voiced beat, an inner voice speaking a line.
##
## "No speakerId" and "a dangling speakerId" BOTH resolve to narration here.
## This function does not distinguish them: turning a dangling id into an error
## is the validator's job, not the runtime's.
static func resolve_speaker(project: Dictionary, dialogue: Dictionary, node: Dictionary) -> Dictionary:
	var id: Variant = effective_speaker_id(dialogue, node)
	if id == null:
		return {"kind": "narration"}

	# Character is preferred when an id somehow matches both. That case is a
	# validator error (ambiguous) and unreachable in valid data.
	var characters: Dictionary = project.get("characters", {})
	if characters.has(id):
		return {"kind": "character", "character": characters[id]}

	var skills: Dictionary = project.get("skills", {})
	if skills.has(id):
		return {"kind": "skill", "skill": skills[id]}

	return {"kind": "narration"}


## The portrait registry id to render, or null.
##
## null is LEGAL AND EXPECTED for a skill or narration speaker — the demo's
## `node_foxglove` is voiced by the `observation` skill precisely so this path
## is exercised. The presentation layer decides whether to hold the last
## character portrait or clear it; that is a display policy, not a runtime one.
static func resolve_portrait(project: Dictionary, dialogue: Dictionary, node: Dictionary) -> Variant:
	# A per-line expression override wins outright, whoever is speaking.
	if node.has("portrait"):
		return node["portrait"]

	var speaker := resolve_speaker(project, dialogue, node)
	if speaker["kind"] == "character":
		var character: Dictionary = speaker["character"]
		if character.has("portrait"):
			return character["portrait"]

	return null


# ----------------------------------------------------------------- shared --


## Returns the node Dictionary, or null when the dialogue has no such node.
static func find_node(dialogue: Dictionary, node_id: String) -> Variant:
	for node in dialogue.get("nodes", []):
		if node is Dictionary and node.get("id", null) == node_id:
			return node
	return null
