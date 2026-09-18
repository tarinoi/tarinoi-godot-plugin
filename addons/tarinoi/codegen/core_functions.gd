@tool
class_name TarinoiCoreFunctionsScaffold

# Renders the reference implementation of Tarinoi's core functions — the
# built-in `Fn.tarinoi.*` set that in-app playback evaluates for real — as a
# GDScript class the game owns.
#
# Codegen writes the result next to the generated bindings, once: the file is
# the game's to edit (a different variable store, savegame hooks, …) and is
# never overwritten. Deleting it gets a fresh copy on the next run.
#
# The set is versioned. VERSION follows the public core_functions.md document;
# a scaffold stamped with an older version is reported by validation so the
# game can merge the changes by hand or re-scaffold.

## Version of the core set this plugin scaffolds. Matches the version line in
## the public core functions document.
const VERSION := "0.0.1"

## Identifier of the function collection holding the set: `Fn.tarinoi.*`.
const COLLECTION := "tarinoi"

## Global class name of the scaffolded implementation.
const CLASS_NAME := "TarinoiCoreFunctions"

## File the scaffold is written to, inside the impl directory.
const FILE_NAME := "tarinoi_core_functions.gd"

## First line of every scaffold. Validation reads the version back from it.
const STAMP_PREFIX := "# Tarinoi core functions "

## The reference bodies, keyed by function name. Each entry is the argument
## list the function must be declared with, and the body lines (unindented).
## A declaration that does not match its entry by name and arity is not a core
## function this plugin knows, and gets an ordinary not-implemented stub.
const FUNCTIONS := {
	"SetFlag": {
		"args": ["flagRef"],
		"doc": "Set a flag.",
		"body": ['_write(flagRef, true)', 'return null'],
	},
	"ClearFlag": {
		"args": ["flagRef"],
		"doc": "Clear a flag.",
		"body": ['_write(flagRef, false)', 'return null'],
	},
	"ToggleFlag": {
		"args": ["flagRef"],
		"doc": "Toggle a flag: clear if set, set if unset.",
		"body": ['_write(flagRef, not _flag(flagRef))', 'return null'],
	},
	"SetCounter": {
		"args": ["counterRef", "value"],
		"doc": "Set a counter to a value, which must be a number.",
		"body": ['_write(counterRef, _number(value))', 'return null'],
	},
	"IncrementCounter": {
		"args": ["counterRef", "delta"],
		"doc": "Increment a counter by delta, which must be a number. Use negative numbers to decrement. An unset counter is treated as a 0.",
		"body": ['_write(counterRef, _number(counterRef) + _number(delta))', 'return null'],
	},
	"SetText": {
		"args": ["textRef", "value"],
		"doc": "Set a text variable to a value, which must be a string.",
		"body": ['_write(textRef, _text(value))', 'return null'],
	},
	"FlagIsSet": {
		"args": ["flagRef"],
		"doc": "Returns true if the flag is set. An unset flag is treated as clear. Use the NOT operator in conditions to negate.",
		"body": ['return _flag(flagRef)'],
	},
	"NumberEquals": {
		"args": ["a", "b"],
		"doc": "Returns true if a and b equal each other. Both must be numbers. An unset counter is treated as a 0. Use the NOT operator in conditions to negate.",
		"body": ['return _number(a) == _number(b)'],
	},
	"NumberAtLeast": {
		"args": ["a", "b"],
		"doc": "Returns true if a >= b. Both must be numbers. An unset counter is treated as a 0.",
		"body": ['return _number(a) >= _number(b)'],
	},
	"NumberGreaterThan": {
		"args": ["a", "b"],
		"doc": "Returns true if a > b. Both must be numbers. An unset counter is treated as a 0.",
		"body": ['return _number(a) > _number(b)'],
	},
	"NumberAtMost": {
		"args": ["a", "b"],
		"doc": "Returns true if a <= b. Both must be numbers. An unset counter is treated as a 0.",
		"body": ['return _number(a) <= _number(b)'],
	},
	"NumberLessThan": {
		"args": ["a", "b"],
		"doc": "Returns true if a < b. Both must be numbers. An unset counter is treated as a 0.",
		"body": ['return _number(a) < _number(b)'],
	},
	"StringEquals": {
		"args": ["a", "b"],
		"doc": "Returns true if a and b equal each other. Both must be strings. An unset text variable is treated as empty. Use the NOT operator in conditions to negate.",
		"body": ['return _text(a) == _text(b)'],
	},
}

## Author-facing order of the set: setters by type, then comparators by type.
## Functions outside the set follow, by name.
const ORDER := [
	"SetFlag", "ClearFlag", "ToggleFlag", "SetCounter", "IncrementCounter", "SetText",
	"FlagIsSet", "NumberEquals", "NumberAtLeast", "NumberGreaterThan", "NumberAtMost",
	"NumberLessThan", "StringEquals",
]

## The helpers every reference body calls. They turn the loosely typed values
## the dispatcher hands over into what the function needs, honouring the
## defaults for unset variables, and log rather than throw on a mismatch.
const HELPERS := """
# ---------------------------------------------------------------------------
# Helpers. The dispatcher passes a Var.* argument as a VarRef so the function
# can write through it, and anything else as a plain value. Unset variables
# read as false / 0 / "", matching in-app playback. A value of the wrong type
# is an authoring error: it is logged, and the default is used instead.
# ---------------------------------------------------------------------------

## Writes through a Var.* reference.
func _write(ref: Variant, value: Variant) -> void:
	if ref is VarRef:
		(ref as VarRef).set_value(value)
		return
	TarinoiLogger.error("core functions: expected a Var.* reference, got %s" % _describe(ref))


## Reads a boolean: a flag, or a literal.
func _flag(v: Variant) -> bool:
	var resolved: Variant = VarRef.resolve(v)
	if resolved == null:
		return false
	if resolved is bool:
		return resolved
	TarinoiLogger.error("core functions: expected a boolean, got %s" % _describe(v))
	return false


## Reads a number: a counter, a list item, or a literal.
func _number(v: Variant) -> float:
	var resolved: Variant = VarRef.resolve(v)
	if resolved == null:
		return 0.0
	if resolved is float or resolved is int:
		return float(resolved)
	TarinoiLogger.error("core functions: expected a number, got %s" % _describe(v))
	return 0.0


## Reads a string: a text variable, a list item, or a literal.
func _text(v: Variant) -> String:
	var resolved: Variant = VarRef.resolve(v)
	if resolved == null:
		return ""
	if resolved is String or resolved is StringName:
		return String(resolved)
	TarinoiLogger.error("core functions: expected a string, got %s" % _describe(v))
	return ""


static func _describe(v: Variant) -> String:
	if v is VarRef:
		return "%s = %s" % [str(v), str((v as VarRef).get_value())]
	return "%s (%s)" % [str(v), type_string(typeof(v))]
"""


## Renders the scaffold for the declarations synced in the `tarinoi`
## collection. `decls` is the codegen's per-collection array of
## { name, args, returns, effect }. Returns { source, unknown } where
## `unknown` lists the declarations that got a stub instead of a body.
##
## `options` may override, for tests: `base` (the extends expression) and
## `class_name` (empty to omit the global class registration).
static func render(decls: Array, source_label: String, options: Dictionary = {}) -> Dictionary:
	var base: String = options.get("base", "TarinoiFunctions.Tarinoi%sFunctions" % _to_pascal(COLLECTION))
	var cls: String = options.get("class_name", CLASS_NAME)
	var unknown: Array[String] = []

	var out := STAMP_PREFIX + VERSION + " — reference implementation.\n"
	out += "# Scaffolded by Tarinoi codegen from %s.\n" % source_label
	out += "#\n"
	out += "# This file is yours: edit it freely, codegen never overwrites it. Delete it\n"
	out += "# to get a fresh copy the next time you regenerate bindings.\n"
	out += "#\n"
	out += "# These are the Fn.%s.* functions in-app playback evaluates for real. Keep\n" % COLLECTION
	out += "# the same semantics — in particular the defaults for unset variables — so\n"
	out += "# that what an author verified in playback holds in the game.\n"
	if not cls.is_empty():
		out += "class_name %s\n" % cls
	out += "extends %s\n\n" % base

	for decl: Dictionary in _ordered(decls):
		var fn_name: String = decl["name"]
		var arg_names := _arg_names(decl.get("args", []))
		var spec: Variant = FUNCTIONS.get(fn_name)
		if spec == null or (spec as Dictionary)["args"].size() != arg_names.size():
			unknown.append(fn_name)
			out += _stub(fn_name, arg_names, str(decl.get("returns", "")))
			continue
		out += "\n## %s\n" % (spec as Dictionary)["doc"]
		out += "func %s(%s) -> Variant:\n" % [fn_name, _decls((spec as Dictionary)["args"])]
		for line: String in (spec as Dictionary)["body"]:
			out += "\t%s\n" % line
		out += "\n"

	out += HELPERS
	return {"source": out, "unknown": unknown}


## Reads the version stamp from a scaffold's first line; "" if it has none.
static func stamp_version(content: String) -> String:
	var first_line := content.get_slice("\n", 0)
	if not first_line.begins_with(STAMP_PREFIX):
		return ""
	return first_line.substr(STAMP_PREFIX.length()).get_slice(" ", 0)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## A declaration this plugin has no body for: the same not-implemented stub the
## generated base class carries, so the mismatch is loud at runtime too.
static func _stub(fn_name: String, arg_names: Array[String], returns: String) -> String:
	var out := "\n## %s(%s) -> %s — not a core function this plugin knows; implement it.\n" % [
		fn_name, ", ".join(arg_names), returns]
	out += "func %s(%s) -> Variant:\n" % [fn_name, _decls(arg_names)]
	out += '\tpush_error("%s.%s is not implemented")\n' % [CLASS_NAME, fn_name]
	out += "\treturn %s\n\n" % TarinoiCodegen._default_return(returns)
	return out


static func _ordered(decls: Array) -> Array:
	var sorted := decls.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := _rank(a["name"])
		var rb := _rank(b["name"])
		if ra != rb:
			return ra < rb
		return str(a["name"]) < str(b["name"]))
	return sorted


static func _rank(fn_name: String) -> int:
	var i := ORDER.find(fn_name)
	return ORDER.size() if i == -1 else i


static func _arg_names(args: Array) -> Array[String]:
	var names: Array[String] = []
	for a: Variant in args:
		if a is Dictionary:
			var n := str((a as Dictionary).get("arg_name", ""))
			if not n.is_empty():
				names.append(n)
	return names


static func _decls(arg_names: Array) -> String:
	var decls: Array[String] = []
	for n: Variant in arg_names:
		decls.append("%s: Variant" % n)
	return ", ".join(decls)


static func _to_pascal(s: String) -> String:
	return TarinoiCodegen._to_pascal(s)
