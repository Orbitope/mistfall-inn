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

var _pass := 0
var _fail := 0
var _skip := 0
var _failures: Array[String] = []


func _init() -> void:
	print("Parlance conformance — port: GDScript\n")
	_print_pin()

	_run_rng()
	_skip_family("evaluate.json", "evaluate")
	_skip_family("apply_effect.json", "applyEffect")
	_skip_family("resolve_check.json", "resolveCheck")
	_skip_family("step_dialogue.json", "stepDialogue")
	_skip_family("choose_choice.json", "chooseChoice")
	_skip_family("advance.json", "advanceNode")
	_skip_family("resolveCharacterDialogue.json", "resolveCharacterDialogue")
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


func _report() -> void:
	print("\n%d passed, %d failed, %d skipped (not yet ported)" % [_pass, _fail, _skip])
	if not _failures.is_empty():
		print("\nFailures:")
		for f in _failures:
			print("  ", f)
	if _fail > 0:
		print("\nThe vectors are the contract. Fix the port, never the vector.")
	quit(1 if _fail > 0 else 0)
