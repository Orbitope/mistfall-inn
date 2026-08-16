class_name ParlanceInterpolate
extends RefCounted

## `{var_id}` substitution for player-facing strings.
##
## A substitution layer, not an expression language: no conditionals, no
## formatting, no arithmetic, and deliberately no recursion — a substituted
## value containing `{another_id}` is left alone, one pass only.
##
## The two rules that matter at runtime:
##
##   * A missing value NEVER throws and is never rendered as "". The
##     placeholder passes through exactly as authored, so an unset variable is
##     loudly visible in-game instead of silently blanking a line.
##   * An empty string that IS set substitutes normally. `has()`, not
##     truthiness — those two cases are different and only one is a bug.
##
## Ids must match `^[a-z][a-z0-9_]*$`, so `{Not An Id}` and `{}` are ordinary
## text. There is no escape syntax in v1: a `{` followed by a valid id and `}`
## IS a placeholder, and that is documented rather than solved.

##
## Types are the preloaded const, not the global `class_name`: a headless
## `--script` run has no warm global-class cache, so `ParlanceState` does not
## resolve there even though it does in the editor.

const PLACEHOLDER := "\\{([a-z][a-z0-9_]*)\\}"
const State := preload("res://addons/parlance/state.gd")

static var _re: RegEx = null


static func interpolate(text: String, state: State) -> String:
	# Fast path. Most authored lines carry no placeholder, and the contract
	# wants the ORIGINAL string back when nothing was substituted.
	if not text.contains("{"):
		return text

	if _re == null:
		_re = RegEx.create_from_string(PLACEHOLDER)

	var out := ""
	var pos := 0
	for m in _re.search_all(text):
		out += text.substr(pos, m.get_start() - pos)
		var id := m.get_string(1)
		# has(), not a truthiness test: a set-but-empty value substitutes.
		out += str(state.texts[id]) if state.texts.has(id) else m.get_string(0)
		pos = m.get_end()
	return out + text.substr(pos)
