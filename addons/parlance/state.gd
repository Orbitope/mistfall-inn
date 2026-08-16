class_name ParlanceState
extends RefCounted

## The runtime's GameState, and the ONE place the serialized shape is decided.
##
## Two rules from the contract are easy to get subtly wrong, so they live here
## rather than in each caller:
##
##   1. Eight keys are ALWAYS emitted; four are emitted ONLY when non-empty
##      (`texts`, `relationships`, `questFired`, `pendingCutscene`). The
##      conformance vectors compare by deep equality, so emitting `"texts": {}`
##      where the reference omits the key is a failure, not a cosmetic
##      difference. This was read off the vectors, not guessed.
##
##   2. Missing keys read as defaults and NEVER throw. Every accessor here
##      takes a default; nothing indexes a dictionary bare.
##
## `inventory` and `questFired` are sets in the contract and dictionaries here
## (GDScript has no set type). They serialize back to SORTED arrays — the
## reference emits sorted, and unsorted would fail deep equality.

var flags := {}
var reputation := {}
var skills := {}
var counters := {}
var inventory := {}  ## id -> true. A set; see note above.
var quest_stages := {}
var relationships := {}
var xp: float = 0.0
var skill_points_spent := {}
var texts := {}
var quest_fired := {}  ## "quest/kind/id" -> true. A set.
var pending_cutscene = null  ## String id, or null when nothing is queued.


static func from_dict(d: Dictionary) -> Variant:
	var s = new()
	s.flags = _sub(d, "flags")
	s.reputation = _sub(d, "reputation")
	s.skills = _sub(d, "skills")
	s.counters = _sub(d, "counters")
	s.quest_stages = _sub(d, "questStages")
	s.relationships = _sub(d, "relationships")
	s.skill_points_spent = _sub(d, "skillPointsSpent")
	s.texts = _sub(d, "texts")
	s.xp = float(d.get("xp", 0))
	for item in d.get("inventory", []):
		s.inventory[item] = true
	for key in d.get("questFired", []):
		s.quest_fired[key] = true
	# Absent and explicit-null both mean "nothing queued". The reference omits
	# the key entirely rather than writing null, but tolerate both on the way in.
	var pending = d.get("pendingCutscene", null)
	s.pending_cutscene = pending if pending is String else null
	return s


static func _sub(d: Dictionary, key: String) -> Dictionary:
	var v = d.get(key, null)
	return (v as Dictionary).duplicate(true) if v is Dictionary else {}


func to_dict() -> Dictionary:
	var inv := inventory.keys()
	inv.sort()

	var out := {
		"flags": flags.duplicate(true),
		"reputation": reputation.duplicate(true),
		"skills": skills.duplicate(true),
		"counters": counters.duplicate(true),
		"inventory": inv,
		"questStages": quest_stages.duplicate(true),
		"xp": xp,
		"skillPointsSpent": skill_points_spent.duplicate(true),
	}

	# Omitted-when-empty, so states written before these fields existed still
	# round-trip unchanged. Order of the checks is irrelevant; presence is not.
	if not texts.is_empty():
		out["texts"] = texts.duplicate(true)
	if not relationships.is_empty():
		out["relationships"] = relationships.duplicate(true)
	if not quest_fired.is_empty():
		var fired := quest_fired.keys()
		fired.sort()
		out["questFired"] = fired
	if pending_cutscene != null:
		out["pendingCutscene"] = pending_cutscene

	return out


## A deep copy. Every mutating entry point in the runtime copies first and
## returns the copy — the contract's immutability rule is enforced here, once,
## rather than trusted to each effect handler.
func copy() -> Variant:
	var s = new()
	s.flags = flags.duplicate(true)
	s.reputation = reputation.duplicate(true)
	s.skills = skills.duplicate(true)
	s.counters = counters.duplicate(true)
	s.inventory = inventory.duplicate(true)
	s.quest_stages = quest_stages.duplicate(true)
	s.relationships = relationships.duplicate(true)
	s.xp = xp
	s.skill_points_spent = skill_points_spent.duplicate(true)
	s.texts = texts.duplicate(true)
	s.quest_fired = quest_fired.duplicate(true)
	s.pending_cutscene = pending_cutscene
	return s
