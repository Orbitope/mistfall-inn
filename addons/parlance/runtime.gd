class_name ParlanceRuntime
extends RefCounted

## The Parlance runtime, ported to GDScript.
##
## Ported families: evaluate, applyEffect, resolveCheck, stepDialogue,
## chooseChoice, advanceNode. NOT ported: resolveQuests, progression,
## resolveCharacterDialogue. The conformance runner reports those as SKIP
## rather than passing them by omission.
##
## `project` is a plain Dictionary in the vectors' MinimalProject shape
## (`{"factions": {...}, "quests": {...}}`). Missing sub-objects are legal and
## mean "no data": an unknown faction applies its delta unclamped, an unknown
## quest is false for every op. Nothing here throws on missing project data.
##
## ERRORS. GDScript has no exceptions, so the one family with a throw contract
## (`advance_node`) returns `{"error": "..."}` instead. Callers must check for
## that key — see the function's own note. Every other entry point is total.

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
			# The feed model: a flag, not a separate map. The character's ladder
			# carries a high-priority rung gated on it, and `dialogue` is
			# metadata for tooling. Clear it with an ordinary set_flag false.
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
static func resolve_check(check: Dictionary, state: State, rng: Callable, default_dice = null, criticals := false) -> Dictionary:
	var notation := str(check.get("dice", default_dice if default_dice != null else "1d20"))
	var spec := parse_dice(notation)

	var faces: Array[int] = []
	for _i in spec.n:
		faces.append(int(floor(float(rng.call()) * spec.m)) + 1)

	var roll := 0
	for face in faces:
		roll += face

	var skill_value := float(state.skills.get(check.get("skill", ""), 0))
	var total := float(roll) + skill_value
	var passed := total >= float(check.get("difficulty", 0))

	var result := {
		"passed": passed,
		"roll": roll,
		"total": total,
		"skillValue": skill_value,
		"dice": "%dd%d" % [spec.n, spec.m],
	}

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
		var result := resolve_check(check, next_state, rng, rules.get("dice", null), bool(rules.get("criticals", false)))
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
	if find_node(dialogue, target_id) == null:
		return {"error": "next target '%s' does not exist in dialogue '%s'" % [target_id, dialogue.get("id", "?")]}

	return {"nextNodeId": target_id, "newState": state}


# ------------------------------------------- resolveCharacterDialogue (feed) --


## Which dialogue this character offers right now, or null.
##
## Walks `character.dialogues` — the ladder — IN ORDER and returns the first
## rung whose `showIf` passes; a rung with no `showIf` always passes. Array
## order is the whole mechanism: the specific, conditional rungs sit above the
## general fallback, so first-match-wins reads as "the most specific thing this
## character has to say today".
##
## Returns null when the ladder is absent, empty, or nothing matches.
##
## The feed model: there is no `activeDialogues` map. `set_active_dialogue`
## sets the flag `active_dialogue__{character}`, and a high-priority rung gated
## on that flag is what pins a character to one conversation.
static func resolve_character_dialogue(state: State, character: Dictionary, project := {}) -> Variant:
	for rung in character.get("dialogues", []):
		if not rung is Dictionary:
			continue
		if rung.has("showIf") and not evaluate(rung["showIf"], state, project):
			continue
		return rung.get("dialogue", null)
	return null


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
## A dialogue-level speakerId is character-only (it doubles as ownership for
## ladder resolution); only the NODE level may name a skill — that is the
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
