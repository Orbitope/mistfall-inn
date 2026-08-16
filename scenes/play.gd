extends Control

## The playable mystery: a location loop over the CC0 narrative data, driven by
## the ported runtime.
##
## Two modes. In LOCATION mode you see where you are and pick an interactable
## or an exit; in DIALOGUE mode you read a beat and pick a line. Everything
## conditional — which choices show, which exits open, which conversation a
## character offers, when the militia arrives — is decided by the runtime
## against authored data. This file only presents it.
##
## No art beyond the three portraits, and no layout craft. The point is that
## the whole mystery is reachable, not that it is pretty.

const State := preload("res://addons/parlance/state.gd")
const Runtime := preload("res://addons/parlance/runtime.gd")
const Rng := preload("res://addons/parlance/rng.gd")

const PORTRAIT_DIR := "res://assets/portraits/"

## Where the night starts. `loc_common_room` carries the `start` tag.
const START_LOCATION := "loc_common_room"

## Fixed so a playthrough is reproducible. A real game would seed per session.
const SEED := 12345

var _project := {}
var _state: Variant

var _location := {}
var _dialogue := {}
var _node_id := ""
var _step := 0

## on_enter interactables already fired, so an arrival trigger whose `showIf`
## is STILL true when its dialogue ends does not immediately re-fire and trap
## the player in a loop. Firing each at most once per session is the cheap
## correct guard: every one of them is a one-time beat by design.
var _fired: Dictionary = {}

## Dialogues the player has read to the end, so the location list can mark what
## has already been looked at. Presentation only — nothing in the runtime or
## the authored data reads this.
var _seen: Dictionary = {}

## The last roll, rendered above the node it produced, then cleared.
var _last_check := ""

@onready var _portrait: TextureRect = $Margin/Rows/Top/Portrait
@onready var _text: RichTextLabel = $Margin/Rows/Top/Text
@onready var _choices: VBoxContainer = $Margin/Rows/Choices
@onready var _status: Label = $Margin/Rows/Status
@onready var _skills: Label = $Margin/Rows/Skills


func _ready() -> void:
	_project = _load_project()
	_state = State.from_dict(_initial_state())
	_enter_location(START_LOCATION)


# ------------------------------------------------------------------ loading --


func _load_project() -> Dictionary:
	return {
		"dialogues": _load_dir("res://data/dialogues"),
		"locations": _load_dir("res://data/locations"),
		"endings": _load_dir("res://data/endings"),
		"quests": _load_dir("res://data/quests"),
		"factions": _load_dir("res://data/factions"),
		"characters": _load_dir("res://data/characters"),
		"skills": _load_registry("res://data/skills.json", "skills"),
		"portraits": _load_registry("res://data/portraits.json", "portraits"),
	}


func _load_dir(path: String) -> Dictionary:
	var out := {}
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		var f := FileAccess.open(path + "/" + file_name, FileAccess.READ)
		if f == null:
			continue
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary and parsed.has("id"):
			out[parsed["id"]] = parsed
	return out


func _load_registry(path: String, key: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return out
	for entry in parsed.get(key, []):
		if entry is Dictionary and entry.has("id"):
			out[entry["id"]] = entry
	return out


## The character's opening skill loadout, from `progression.json`.
##
## `createDefaultState` leaves skills EMPTY by contract — the caller is meant to
## set them for a real session, and this is that caller. Without this every
## check rolls at skill 0, which is not "unskilled", it is a bug: the authored
## difficulties assume this preset, so a DC 9 check meant to be comfortable
## becomes a coin flip.
##
## This is the preset only, not the progression machinery. Nothing here grants
## XP or spends points, so `effectiveSkill` reduces to the starting value and
## the SKIPPED `progression` family is genuinely not needed.
func _starting_skills() -> Dictionary:
	var f := FileAccess.open("res://data/progression.json", FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return {}
	var out := {}
	for skill_id in parsed.get("startingSkills", {}):
		out[skill_id] = float(parsed["startingSkills"][skill_id])
	return out


## Seeds flags and counters from `variables.json` defaults, per the contract's
## createDefaultState. A text variable with no default is OMITTED rather than
## set to "" — that absence is what makes an unset value loudly visible.
func _initial_state() -> Dictionary:
	var seeded := {"flags": {}, "counters": {}, "texts": {}, "skills": _starting_skills()}
	var f := FileAccess.open("res://data/variables.json", FileAccess.READ)
	if f == null:
		return seeded
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return seeded
	for v in parsed.get("variables", []):
		if not (v is Dictionary and v.has("id")):
			continue
		match v.get("kind", ""):
			"flag": seeded["flags"][v["id"]] = bool(v.get("default", false))
			"counter": seeded["counters"][v["id"]] = float(v.get("default", 0))
			"text":
				if v.has("default"):
					seeded["texts"][v["id"]] = v["default"]
	return seeded


# ----------------------------------------------------------------- location --


func _enter_location(location_id: String) -> void:
	var locations: Dictionary = _project.get("locations", {})
	if not locations.has(location_id):
		_text.text = "[color=red]Unknown location '%s'.[/color]" % location_id
		return
	_location = locations[location_id]

	# Arrival triggers first: an on_enter interactable whose showIf passes
	# takes over the screen before the player is offered anything.
	var triggered := _pending_trigger()
	if triggered != "":
		_start_dialogue(triggered)
		return

	_render_location()


## The first unfired on_enter interactable whose showIf passes, or "".
func _pending_trigger() -> String:
	for item in _location.get("interactables", []):
		if not (item is Dictionary and item.get("trigger", "") == "on_enter"):
			continue
		if _fired.has(item.get("id", "")):
			continue
		if item.has("showIf") and not Runtime.evaluate(item["showIf"], _state, _project):
			continue
		# Resolve BEFORE marking it fired. An NPC trigger whose ladder offers
		# nothing right now resolves to "", and marking first would burn the
		# trigger permanently on a beat that never played.
		var dialogue_id := _dialogue_for(item)
		if dialogue_id == "":
			continue
		_fired[item.get("id", "")] = true
		return dialogue_id
	return ""


## An interactable's dialogue. For an NPC that means asking the runtime which
## rung of the character's ladder applies right now — not a fixed dialogue id.
func _dialogue_for(item: Dictionary) -> String:
	if item.get("kind", "") == "npc":
		var characters: Dictionary = _project.get("characters", {})
		var character_id = item.get("character", "")
		if not characters.has(character_id):
			return ""
		var resolved: Variant = Runtime.resolve_character_dialogue(
			_state, characters[character_id], _project
		)
		return str(resolved) if resolved != null else ""
	return str(item.get("dialogue", ""))


func _render_location() -> void:
	_dialogue = {}
	_portrait.texture = null
	_text.text = "[b]%s[/b]\n\n%s" % [
		_location.get("name", "?"), _location.get("description", "")
	]

	_clear_choices()

	for item in _location.get("interactables", []):
		if not (item is Dictionary) or item.get("trigger", "") == "on_enter":
			continue
		if item.has("showIf") and not Runtime.evaluate(item["showIf"], _state, _project):
			continue
		var dialogue_id := _dialogue_for(item)
		if dialogue_id == "":
			continue  # An NPC whose ladder currently offers nothing.
		# Keyed on the RESOLVED dialogue, not the interactable. That is what
		# makes a character with something new to say read as unvisited: once
		# Bragg's ladder moves to `dlg_bragg_pressed`, the tick clears itself.
		var seen := "✓ " if _seen.has(dialogue_id) else "• "
		_add_button(seen + _label_for(item, dialogue_id), _on_interact.bind(dialogue_id))

	for exit in _location.get("exits", []):
		if exit is Dictionary:
			_add_button("→ %s" % _exit_label(exit), _on_exit.bind(exit))

	_update_status()


func _label_for(item: Dictionary, dialogue_id: String) -> String:
	if item.get("kind", "") == "npc":
		var characters: Dictionary = _project.get("characters", {})
		var character = characters.get(item.get("character", ""), {})
		return "Speak to %s" % character.get("name", item.get("character", "?"))
	var dialogues: Dictionary = _project.get("dialogues", {})
	var dialogue = dialogues.get(dialogue_id, {})
	return str(dialogue.get("title", dialogue_id))


func _exit_label(exit: Dictionary) -> String:
	var locations: Dictionary = _project.get("locations", {})
	var target = locations.get(exit.get("to", {}).get("location", ""), {})
	return str(target.get("name", exit.get("id", "?")))


## Exits may be gated. A gate that fails is not a dead end: the exit plays its
## `denialDialogue` instead, which is where the authored reason lives.
func _on_exit(exit: Dictionary) -> void:
	if exit.has("gate") and not Runtime.evaluate(exit["gate"], _state, _project):
		var denial := str(exit.get("denialDialogue", ""))
		if denial != "":
			_start_dialogue(denial)
		return
	_enter_location(str(exit.get("to", {}).get("location", "")))


func _on_interact(dialogue_id: String) -> void:
	_start_dialogue(dialogue_id)


# ----------------------------------------------------------------- dialogue --


func _start_dialogue(dialogue_id: String) -> void:
	var dialogues: Dictionary = _project.get("dialogues", {})
	if not dialogues.has(dialogue_id):
		_text.text = "[color=red]Unknown dialogue '%s'.[/color]" % dialogue_id
		return
	_dialogue = dialogues[dialogue_id]
	_enter_node(str(_dialogue.get("entry", "")))


## Arrives at a node: applies its onEnter effects ONCE, then renders.
##
## The runtime returns onEnter effects without applying them — deciding when
## they fire is the caller's job, and this is that caller. Firing on arrival
## and not on re-render is what stops a rewind double-counting evidence.
func _enter_node(node_id: String) -> void:
	_node_id = node_id

	var step: Dictionary = Runtime.step_dialogue(_dialogue, node_id, _state, _project)
	if step.has("error"):
		_text.text = "[color=red]%s[/color]" % step["error"]
		return

	_state = Runtime.apply_effects(step["onEnterEffects"], _state, _project)
	# Re-step so any interpolated text sees the post-onEnter state.
	step = Runtime.step_dialogue(_dialogue, node_id, _state, _project)

	_render_node(step)


func _render_node(step: Dictionary) -> void:
	var node: Dictionary = step["node"]
	_render_portrait(node)
	_clear_choices()

	# Which choices are points of no return, worked out before anything is
	# drawn so the node can be labelled as a whole.
	var visible: Array = step["visibleChoices"]
	var terminal: Array = []
	for choice in visible:
		terminal.append(_choice_ends_night(choice))

	var ending_count := 0
	for is_end in terminal:
		if is_end:
			ending_count += 1

	# A banner on the NODE, not a tag repeated on every line. When every answer
	# is final the node itself is the point of no return and saying so once is
	# clearer; when only some are, the banner cannot speak for the whole node,
	# so those individual choices keep their own mark.
	var banner := ""
	if ending_count > 0 and ending_count == visible.size():
		banner = "[b]※ This is the last thing you will do tonight.[/b]\n[i]Every answer here ends it.[/i]\n\n"
	elif ending_count > 0:
		banner = "[b]※ Some answers here end the night.[/b]\n\n"

	var roll := ""
	if _last_check != "":
		roll = "[i]%s[/i]\n\n" % _last_check
		_last_check = ""

	_text.text = banner + roll + str(node.get("text", ""))

	for i in visible.size():
		var choice: Dictionary = visible[i]
		var label := str(choice.get("text", ""))
		label += _check_hint(choice)
		# Only mark individually when the banner could not say it for everyone.
		if terminal[i] and ending_count != visible.size():
			label += "        [ends the night]"
		_add_button(label, _on_choice.bind(str(choice.get("id", ""))))

	# No choices does NOT mean the conversation is over. A listen-only beat
	# advances through `next`, and treating that as the end silently truncates
	# every such chain — which is exactly what this scene used to do, making
	# `node_lantern` (and with it the whole stable yard) unreachable.
	if visible.is_empty():
		if node.has("next"):
			_add_button("(continue)", _on_advance)
		else:
			_add_button("(continue)", _leave_dialogue)

	_update_status()


func _on_choice(choice_id: String) -> void:
	# Keyed on step index rather than a running stream, so replaying a step
	# reproduces its roll — the same property the reference session has.
	var rng: Callable = Rng.for_step(SEED, _step)
	_step += 1

	var outcome: Dictionary = Runtime.choose_choice(
		_dialogue, _node_id, choice_id, _state, _project, rng
	)
	if outcome.has("error"):
		_text.text = "[color=red]%s[/color]" % outcome["error"]
		return

	_state = outcome["newState"]

	if outcome.has("checkResult"):
		var r: Dictionary = outcome["checkResult"]
		var check: Dictionary = _current_choice(choice_id).get("check", {})
		var skills: Dictionary = _project.get("skills", {})
		var skill_name := str(skills.get(check.get("skill", ""), {}).get("name", check.get("skill", "")))
		# Held for the NEXT node to display: the roll explains the beat the
		# player is about to read, so it belongs above that text, not here.
		_last_check = "%s — rolled %d + %d = %d vs %d · %s%s" % [
			skill_name, int(r["roll"]), int(r["skillValue"]), int(r["total"]),
			int(check.get("difficulty", 0)),
			"PASSED" if r["passed"] else "FAILED",
			("  (critical %s)" % r["critical"]) if r.has("critical") else "",
		]
		print("check %s: %s" % [r["dice"], _last_check])

	var next: Variant = outcome["nextNodeId"]
	if next == null:
		_leave_dialogue()
		return
	_enter_node(str(next))


## The choice dictionary by id on the current node, or {}.
func _current_choice(choice_id: String) -> Dictionary:
	var node: Variant = Runtime.find_node(_dialogue, _node_id)
	if node == null:
		return {}
	for choice in node.get("choices", []):
		if choice is Dictionary and choice.get("id", null) == choice_id:
			return choice
	return {}


## Resolves a listen-only beat's `next` — one hop, never a chain.
##
## `advance_node` applies no effects and resolves no check: `next` carries
## neither. The TARGET's onEnter is applied by `_enter_node` on arrival, which
## is what makes arriving by `next` and arriving by `goto` produce identical
## state — the property the conformance suite's parity vectors exist to pin.
func _on_advance() -> void:
	var outcome: Dictionary = Runtime.advance_node(_dialogue, _node_id, _state)
	if outcome.has("error"):
		_text.text = "[color=red]%s[/color]" % outcome["error"]
		return
	_enter_node(str(outcome["nextNodeId"]))


## Back to the room — unless the night is over.
##
## Re-checks arrival triggers, which is how the militia beat reaches the
## player: `int_militia` is gated on evidence_count >= 3, so it fires on the
## first return AFTER the third piece of evidence lands.
func _leave_dialogue() -> void:
	if _dialogue.has("id"):
		_seen[_dialogue["id"]] = true
	if _check_ending():
		return
	_enter_location(str(_location.get("id", START_LOCATION)))


## Shows an ending and stops, if one has been reached.
##
## An ending's `unlockedBy` IS a `questOutcome` condition, so it goes straight
## to `evaluate` — no quest machinery needed. That works because the contract
## makes `questOutcome` re-evaluate the outcome's own `reachedWhen` against
## current state rather than reading a fired-record, which keeps it independent
## of whether `resolveQuests` has ever been called. This port does not
## implement `resolveQuests` at all, and the endings still resolve correctly.
func _check_ending() -> bool:
	var ending: Variant = _ending_for(_state)
	if ending == null:
		return false

	_dialogue = {}
	_portrait.texture = null
	_text.text = "[b]%s[/b]\n\n%s" % [
		ending.get("name", "?"), ending.get("summary", "")
	]
	_clear_choices()
	_status.text = "— %s —" % ending.get("kind", "end")
	return true


## The ending reached in the given state, or null. Takes the state as an
## argument rather than reading `_state` so it can be asked hypothetically —
## see `_choice_ends_night`.
func _ending_for(state: Variant) -> Variant:
	for ending in _project.get("endings", {}).values():
		if not (ending is Dictionary and ending.has("unlockedBy")):
			continue
		if Runtime.evaluate(ending["unlockedBy"], state, _project):
			return ending
	return null


## The bracket appended to a choice that carries a check: which skill, your
## rating, the difficulty, and the odds.
##
## PASSIVE checks are excluded deliberately. They never roll — the contract
## treats them as a plain goto with a reveal effect — so quoting odds on one
## would be inventing a gamble the runtime will not take.
func _check_hint(choice: Dictionary) -> String:
	var check: Variant = choice.get("check", null)
	if not (check is Dictionary and check.get("mode", "") == "active"):
		return ""

	var skill_id := str(check.get("skill", ""))
	var skills: Dictionary = _project.get("skills", {})
	var skill_name := str(skills.get(skill_id, {}).get("name", skill_id))

	return "        [%s %d vs %d — %d%%]" % [
		skill_name,
		int(_state.skills.get(skill_id, 0)),
		int(check.get("difficulty", 0)),
		round(_check_chance(check)),
	]


## The odds a check passes right now, as a percentage.
##
## Computed from the dice distribution rather than assumed to be d20-linear, so
## it stays honest if a check ever declares `2d6` — a bell curve and a flat d20
## give very different answers for the same difficulty.
##
## Criticals are folded in when the project enables them: an all-minimum roll
## always fails and an all-maximum roll always succeeds, each exactly one
## combination out of m^n, so they are added or removed at the edges rather
## than changing the body of the distribution.
func _check_chance(check: Dictionary) -> float:
	var rules: Dictionary = {}
	if _project.get("rules", null) is Dictionary:
		rules = _project["rules"].get("check", {})

	var notation := str(check.get("dice", rules.get("dice", "1d20")))
	var spec: Dictionary = Runtime.parse_dice(notation)
	var n: int = spec["n"]
	var m: int = spec["m"]

	# ways[s] = number of face combinations summing to s.
	var ways: Array = [1.0]
	for _die in n:
		var next: Array = []
		next.resize(ways.size() + m)
		next.fill(0.0)
		for s in ways.size():
			if ways[s] == 0.0:
				continue
			for face in range(1, m + 1):
				next[s + face] += ways[s]
		ways = next

	var total := pow(float(m), float(n))
	var skill := float(_state.skills.get(check.get("skill", ""), 0))
	var difficulty := float(check.get("difficulty", 0))

	var passing := 0.0
	for s in ways.size():
		if float(s) + skill >= difficulty:
			passing += ways[s]

	if bool(rules.get("criticals", false)):
		# All-minimum always fails; drop it if it was counted as a pass.
		if float(n) + skill >= difficulty:
			passing -= 1.0
		# All-maximum always succeeds; add it if it was counted as a failure.
		if float(n * m) + skill < difficulty:
			passing += 1.0

	return clampf(passing / total * 100.0, 0.0, 100.0)


## Would taking this choice end the night?
##
## Answered by SIMULATION, not by hardcoding which dialogue is the accusation:
## apply the choice's effects, apply the destination node's onEnter, and ask
## whether any ending unlocks. Safe to run speculatively because every runtime
## entry point here is pure — `apply_effects` returns a new state and never
## touches `_state`.
##
## An active check forks, so BOTH branches are tested: a choice that ends the
## night only on a failed roll still deserves the warning.
func _choice_ends_night(choice: Dictionary) -> bool:
	var after: Variant = Runtime.apply_effects(choice.get("effects", []), _state, _project)

	var targets: Array = []
	var check: Variant = choice.get("check", null)
	if check is Dictionary and check.get("mode", "") == "active":
		targets.append(check.get("onSuccess", null))
		targets.append(check.get("onFailure", null))
	else:
		targets.append(choice.get("goto", null))

	for target in targets:
		if target == null:
			continue
		var node: Variant = Runtime.find_node(_dialogue, str(target))
		if node == null:
			continue
		var arrived: Variant = Runtime.apply_effects(node.get("onEnter", []), after, _project)
		if _ending_for(arrived) != null:
			return true
	return false


# ------------------------------------------------------------------- render --


## Renders the resolved portrait, or CLEARS it.
##
## Clearing is a decision, not a fallback. `resolve_portrait` returns null for
## a skill-voiced or narration beat, and the contract leaves the hold-or-clear
## call to the presentation layer. Holding the last face would attribute a
## character a line they do not speak.
func _render_portrait(node: Dictionary) -> void:
	var portrait_id: Variant = Runtime.resolve_portrait(_project, _dialogue, node)
	if portrait_id == null:
		_portrait.texture = null
		return
	var path := PORTRAIT_DIR + str(portrait_id) + ".png"
	_portrait.texture = load(path) if ResourceLoader.exists(path) else null


func _clear_choices() -> void:
	for child in _choices.get_children():
		_choices.remove_child(child)
		child.queue_free()


func _add_button(label: String, handler: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(handler)
	_choices.add_child(button)


func _update_status() -> void:
	var held: Array = _state.inventory.keys()
	held.sort()

	var have := int(_state.counters.get("evidence_count", 0))
	var evidence := "evidence: %d" % have
	var threshold := _militia_threshold()
	if threshold > 0:
		evidence = "evidence: %d / %d" % [have, threshold]
		if have == threshold - 1:
			evidence += "   (one more brings the militia)"

	_status.text = "%s      %s" % [
		evidence,
		("carrying: " + ", ".join(held)) if not held.is_empty() else "carrying nothing",
	]

	# Skills are fixed for the whole night — nothing in this project grants XP
	# or spends points — but they are what every check is rolled against, so
	# they are shown rather than left implicit.
	var parts: Array = []
	for skill_id in _project.get("skills", {}):
		parts.append("%s %d" % [
			str(_project["skills"][skill_id].get("name", skill_id)),
			int(_state.skills.get(skill_id, 0)),
		])
	_skills.text = "  ·  ".join(parts)


## How much evidence summons the militia, read out of the authored data rather
## than hardcoded — the number lives in `loc_common_room`'s on_enter gate, and
## re-typing it here would let the UI and the trigger drift apart silently.
## Returns 0 if no such gate is found, in which case the count is shown bare.
func _militia_threshold() -> int:
	for location in _project.get("locations", {}).values():
		if not location is Dictionary:
			continue
		for item in location.get("interactables", []):
			if not (item is Dictionary and item.get("trigger", "") == "on_enter"):
				continue
			var gate: Variant = item.get("showIf", null)
			if gate is Dictionary and gate.get("type", "") == "counter" \
					and gate.get("counter", "") == "evidence_count":
				return int(gate.get("value", 0))
	return 0
