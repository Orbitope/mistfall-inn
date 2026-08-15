class_name ParlanceRng
extends RefCounted

## Deterministic seeded RNG — mulberry32, bit-for-bit identical to the reference.
##
## This is the single most fragile part of the port. Every check outcome in the
## game derives from it, so a divergence in the low bits does not crash: it
## silently produces a different story than the one the author playtested, and
## the conformance vectors are the only thing that would ever tell you.
##
## Two traps, both from JavaScript semantics that GDScript does not share:
##
##   1. JS numbers are doubles and its bitwise operators coerce to 32 bits.
##      GDScript ints are 64-bit signed, so every step must be masked back to
##      u32 explicitly or the values drift upward and never wrap.
##
##   2. `Math.imul` is a 32-bit multiply. Doing it naively here overflows —
##      two u32 operands multiply to as much as 2^64, which does not fit in a
##      64-bit *signed* int. Hence the 16-bit split in `_imul` below.

const U32 := 0xFFFFFFFF


## JavaScript's `Math.imul(a, b)`, in the unsigned domain.
##
## Splits `a` into 16-bit halves so no intermediate exceeds 2^63. The high half
## only contributes bits that survive mod 2^32, so it is masked before shifting
## rather than after — masking after would be the overflow this exists to avoid.
static func _imul(a: int, b: int) -> int:
	a &= U32
	b &= U32
	var a_lo := a & 0xFFFF
	var a_hi := (a >> 16) & 0xFFFF
	return ((((a_hi * b) & 0xFFFF) << 16) + (a_lo * b)) & U32


## Returns a callable producing the same float sequence as the reference
## implementation for the same seed. Values are in [0, 1).
static func stream(seed_value: int) -> Callable:
	var state := {"s": seed_value & U32}
	return func() -> float:
		state["s"] = (state["s"] + 0x6d2b79f5) & U32
		var z: int = state["s"]
		z = _imul(z ^ (z >> 15), z | 1)
		z = z ^ ((z + _imul(z ^ (z >> 7), z | 61)) & U32)
		return float((z ^ (z >> 14)) & U32) / 4294967296.0


## The RNG for step `step_index` of a play session: a pure function of the seed
## and the step, never a running stream. Rewinding to a step and replaying it
## must produce the same roll, which a stateful generator could not promise.
static func for_step(seed_value: int, step_index: int) -> Callable:
	return stream(seed_value + step_index)
