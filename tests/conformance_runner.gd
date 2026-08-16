extends SceneTree

## Runs the vendored Parlance conformance vectors against this port.
##
## The vectors are the contract: where the prose in docs/ and a vector disagree,
## the vector wins. So this runner deliberately does no interpreting of its own —
## it loads each file, calls the port, and compares. Any cleverness here would be
## a place for the port to look correct while being wrong.
##
## Run headless:
##   godot --headless --script tests/conformance_runner.gd
##
## Exit code is 0 only if every implemented family passes. Families not yet
## ported are reported as SKIP and do not mask a failure — a suite that goes
## green by not running is the failure mode this is built to avoid.

const VECTOR_DIR := "res://conformance/"
# Preloaded rather than referenced by class_name: a headless --script run does
# not necessarily have a warm global-class cache.
const Rng := preload("res://addons/parlance/rng.gd")
const State := preload("res://addons/parlance/state.gd")
const Runtime := preload("res://addons/parlance/runtime.gd")

var _pass := 0
var _fail := 0
var _skip := 0
var _failures: Array[String] = []


func _init() -> void:
	print("Parlance conformance — port: GDScript\n")
	_print_pin()

	_run_rng()
	_run_family("evaluate.json", "evaluate", _check_evaluate)
	_run_family("apply_effect.json", "applyEffect", _check_apply_effect)
	_run_family("resolve_check.json", "resolveCheck", _check_resolve_check)
	_run_family("step_dialogue.json", "stepDialogue", _check_step_dialogue)
	_run_family("choose_choice.json", "chooseChoice", _check_choose_choice)
	_run_family("advance.json", "advanceNode", _check_advance)
	_run_family("resolveCharacterDialogue.json", "resolveCharacterDialogue", _check_character_dialogue)
	_skip_family("resolve_quests.json", "resolveQuests")
	_skip_family("progression.json", "progression")

	_report()


func _print_pin() -> void:
	var f := FileAccess.open("res://conformance/PIN", FileAccess.READ)
	if f == null:
		return
	for line in f.get_as_text().split("\n"):
		if line.begins_with("parlanceVersion") or line.begins_with("parlanceCommit"):
			print("  ", line)
	print()


func _load(file_name: String) -> Variant:
	var f := FileAccess.open(VECTOR_DIR + file_name, FileAccess.READ)
	if f == null:
		_fail += 1
		_failures.append("%s: cannot open — vectors not vendored?" % file_name)
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null:
		_fail += 1
		_failures.append("%s: not valid JSON" % file_name)
	return parsed


func _skip_family(file_name: String, label: String) -> void:
	var vectors: Variant = _load(file_name)
	var n: int = vectors.size() if vectors is Array else 0
	_skip += n
	print("  SKIP  %-28s %3d vectors — not ported yet" % [label, n])


## rng.json — each case is a seed and the exact float sequence it must produce.
func _run_rng() -> void:
	var vectors: Variant = _load("rng.json")
	if not (vectors is Array):
		return

	var failed_cases := 0
	for case: Dictionary in vectors:
		var seed_value: int = int(case["seed"])
		var expected: Array = case["outputs"]
		var next: Callable = Rng.stream(seed_value)

		for i in expected.size():
			var got: float = next.call()
			var want: float = float(expected[i])
			# Compared as integers, not floats, and not with an epsilon.
			#
			# Every value the generator can produce is exactly k / 2^32 for some
			# u32 k, so multiplying back recovers k precisely. That matters
			# because Godot's JSON parser does not round-trip a full-precision
			# double: the vector holding 0.0003297457005828619 parses to
			# 0.00032974570058286, so a direct float comparison fails even for a
			# bit-perfect port. Recovering k compares what the contract actually
			# specifies — the integer — and stays exact regardless of how lossy
			# any given language's JSON parser is. An epsilon would paper over
			# this too, but would also hide a genuinely wrong low bit, which is
			# the one failure worth catching.
			if int(round(got * 4294967296.0)) != int(round(want * 4294967296.0)):
				failed_cases += 1
				_failures.append(
					"rng seed=" + str(seed_value) + " index=" + str(i)
					+ ": got " + String.num(got, 17) + ", want " + String.num(want, 17)
				)
				break

	if failed_cases == 0:
		_pass += vectors.size()
		print("  PASS  %-28s %3d vectors" % ["mulberry32", vectors.size()])
	else:
		_fail += failed_cases
		print("  FAIL  %-28s %3d/%d cases" % ["mulberry32", failed_cases, vectors.size()])


## Runs one vector file. `checker` takes a vector and returns "" for a pass or
## a human-readable reason for a failure — it never prints or counts, so every
## family reports identically.
func _run_family(file_name: String, label: String, checker: Callable) -> void:
	var vectors: Variant = _load(file_name)
	if not (vectors is Array):
		return

	var failed := 0
	for vector: Dictionary in vectors:
		# Deliberately Variant, then type-checked. A checker that hits a runtime
		# error returns null, and `var reason: String = <null>` coerces to ""
		# silently — which read as a pass and once turned 124 erroring vectors
		# into a green suite. An unusable result is a FAILURE, never a pass.
		var reason: Variant = checker.call(vector)
		if not (reason is String):
			failed += 1
			_failures.append("%s: %s — checker errored (see SCRIPT ERROR above)" % [label, vector.get("description", "?")])
		elif reason != "":
			failed += 1
			_failures.append("%s: %s — %s" % [label, vector.get("description", "?"), reason])

	_pass += vectors.size() - failed
	_fail += failed
	if failed == 0:
		print("  PASS  %-28s %3d vectors" % [label, vectors.size()])
	else:
		print("  FAIL  %-28s %3d/%d vectors" % [label, failed, vectors.size()])


func _check_evaluate(v: Dictionary) -> Variant:
	var got := Runtime.evaluate(v["condition"], State.from_dict(v["state"]), v.get("project", {}))
	var want: bool = v["expected"]
	return "" if got == want else "got %s, want %s" % [got, want]


func _check_apply_effect(v: Dictionary) -> Variant:
	var out := Runtime.apply_effect(v["effect"], State.from_dict(v["state"]), v.get("project", {}))
	return _diff(out.to_dict(), v["expected"])


func _check_resolve_check(v: Dictionary) -> Variant:
	var got := Runtime.resolve_check(
		v["check"],
		State.from_dict(v["state"]),
		_rng_from(v.get("rng", 0)),
		v.get("defaultDice", null),
		bool(v.get("criticals", false)),
	)
	return _diff(got, v["expected"])


func _check_step_dialogue(v: Dictionary) -> Variant:
	var out := Runtime.step_dialogue(v["dialogue"], v["nodeId"], State.from_dict(v["state"]), v.get("project", {}))
	if out.has("error"):
		return "unexpected error: %s" % out["error"]

	var ids: Array = []
	for choice in out["visibleChoices"]:
		ids.append(choice.get("id", null))

	return _diff({
		"visibleChoiceIds": ids,
		"onEnterEffectCount": out["onEnterEffects"].size(),
	}, v["expected"])


func _check_choose_choice(v: Dictionary) -> Variant:
	var out := Runtime.choose_choice(
		v["dialogue"],
		v["nodeId"],
		v["choiceId"],
		State.from_dict(v["state"]),
		v.get("project", {}),
		_rng_from(v.get("rng", 0)),
	)
	if out.has("error"):
		return "unexpected error: %s" % out["error"]

	# Built with exactly the keys produced, then deep-compared — so a
	# checkResult on a vector that expects none is a failure, not a pass.
	var actual := {"nextNodeId": out["nextNodeId"], "newState": out["newState"].to_dict()}
	if out.has("checkResult"):
		actual["checkResult"] = out["checkResult"]
	return _diff(actual, v["expected"])


## The one family with a failure contract. The reference throws; this port
## returns an "error" key (GDScript has no exceptions), and `expectedError` is
## a SUBSTRING the message must contain.
func _check_advance(v: Dictionary) -> Variant:
	var out := Runtime.advance_node(v["dialogue"], v["nodeId"], State.from_dict(v["state"]))

	if v.has("expectedError"):
		if not out.has("error"):
			return "expected an error containing %s, but the call succeeded" % [v["expectedError"]]
		if not str(out["error"]).contains(v["expectedError"]):
			return "error %s does not contain %s" % [out["error"], v["expectedError"]]
		return ""

	if out.has("error"):
		return "unexpected error: %s" % out["error"]

	return _diff({"nextNodeId": out["nextNodeId"], "newState": out["newState"].to_dict()}, v["expected"])


## The vector carries the full Character (with its ladder) as an input field,
## and `expected` is a dialogue id or null.
func _check_character_dialogue(v: Dictionary) -> Variant:
	var got: Variant = Runtime.resolve_character_dialogue(
		State.from_dict(v["state"]), v["character"], v.get("project", {})
	)
	return _diff(got, v["expected"])


## A vector's `rng` is a single float for a one-die roll, or an array with one
## value per die consumed IN ORDER. Overrunning returns 0.0 rather than
## erroring — a port that calls rng() too many times should fail on the roll it
## produces, which names the actual bug, not on an index crash.
func _rng_from(spec) -> Callable:
	var values: Array = spec if spec is Array else [spec]
	var cursor := {"i": 0}
	return func() -> float:
		var i: int = cursor["i"]
		cursor["i"] = i + 1
		return float(values[i]) if i < values.size() else 0.0


func _diff(got, want) -> String:
	if _deep_equal(got, want):
		return ""
	return "got %s, want %s" % [JSON.stringify(got), JSON.stringify(want)]


## Deep equality, written out rather than leaning on `==`.
##
## Two reasons not to use the built-in operator. Godot's Dictionary `==` does
## not promise structural comparison the way the vectors need, and — the real
## trap — JSON numbers arrive as floats, so an expected `xp: 350` and a
## produced `350.0` must compare equal while `true` and `1` must NOT. Hence the
## explicit bool check before the numeric one: in GDScript `true == 1.0`, and
## silently accepting that would let a flag pass as a counter.
func _deep_equal(a, b) -> bool:
	if a is bool or b is bool:
		return a is bool and b is bool and a == b

	if (a is int or a is float) and (b is int or b is float):
		return float(a) == float(b)

	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _deep_equal(a[i], b[i]):
				return false
		return true

	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key):
				return false
			if not _deep_equal(a[key], b[key]):
				return false
		return true

	return a == b


func _report() -> void:
	print("\n%d passed, %d failed, %d skipped (not yet ported)" % [_pass, _fail, _skip])
	if not _failures.is_empty():
		print("\nFailures:")
		for f in _failures:
			print("  ", f)
	if _fail > 0:
		print("\nThe vectors are the contract. Fix the port, never the vector.")
	quit(1 if _fail > 0 else 0)
