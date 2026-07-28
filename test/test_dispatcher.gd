extends GutTest


# Simple function collection — returns fixed or recorded values.
class FakeFunctions:
	var return_value: Variant = true
	var last_call_args: Array = []
	var last_call_name: String = ""

	func AlwaysTrue() -> bool:
		return true

	func AlwaysFalse() -> bool:
		return false

	func ReturnString() -> String:
		return "pass"

	func ReturnFail() -> String:
		return "fail"

	func RecordArgs(a: Variant, b: Variant) -> bool:
		last_call_name = "RecordArgs"
		last_call_args = [a, b]
		return true

	func ReturnArg(a: Variant) -> Variant:
		return a


# Variable collection backed by a Dictionary.
class FakeVariables:
	var _store: Dictionary = {}

	func get_variable(name: String) -> Variant:
		return _store.get(name, null)

	func set_variable(name: String, value: Variant) -> void:
		_store[name] = value


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

var _reg: BindingRegistry
var _fn: FakeFunctions
var _vars: FakeVariables
var _disp: Dispatcher


func before_each() -> void:
	_reg  = BindingRegistry.new()
	_fn   = FakeFunctions.new()
	_vars = FakeVariables.new()
	_disp = Dispatcher.new(_reg)

	_reg.bind_function_collection("global", _fn)
	_reg.bind_variable_collection("player", _vars)


# ---------------------------------------------------------------------------
# eval_condition — literals and logic
# ---------------------------------------------------------------------------

func test_empty_condition_is_true() -> void:
	assert_true(_disp.eval_condition(""))

func test_literal_true() -> void:
	assert_true(_disp.eval_condition("true"))

func test_literal_false() -> void:
	assert_false(_disp.eval_condition("false"))

func test_not_true() -> void:
	assert_false(_disp.eval_condition("!true"))

func test_not_false() -> void:
	assert_true(_disp.eval_condition("!false"))

func test_and_true_true() -> void:
	assert_true(_disp.eval_condition("true && true"))

func test_and_true_false() -> void:
	assert_false(_disp.eval_condition("true && false"))

func test_and_false_true() -> void:
	assert_false(_disp.eval_condition("false && true"))

func test_or_false_false() -> void:
	assert_false(_disp.eval_condition("false || false"))

func test_or_false_true() -> void:
	assert_true(_disp.eval_condition("false || true"))

func test_grouping() -> void:
	# (false || true) && false  →  false
	assert_false(_disp.eval_condition("(false || true) && false"))
	# false || (true && true)   →  true
	assert_true(_disp.eval_condition("false || (true && true)"))


# ---------------------------------------------------------------------------
# eval_condition — function dispatch
# ---------------------------------------------------------------------------

func test_fn_always_true() -> void:
	assert_true(_disp.eval_condition("Fn.global.AlwaysTrue()"))

func test_fn_always_false() -> void:
	assert_false(_disp.eval_condition("Fn.global.AlwaysFalse()"))

func test_fn_not_always_true() -> void:
	assert_false(_disp.eval_condition("!Fn.global.AlwaysTrue()"))

func test_fn_and_literal() -> void:
	assert_true(_disp.eval_condition("Fn.global.AlwaysTrue() && true"))
	assert_false(_disp.eval_condition("Fn.global.AlwaysTrue() && false"))

func test_fn_or_literal() -> void:
	assert_true(_disp.eval_condition("Fn.global.AlwaysFalse() || true"))
	assert_false(_disp.eval_condition("Fn.global.AlwaysFalse() || false"))


# ---------------------------------------------------------------------------
# Short-circuit evaluation
# ---------------------------------------------------------------------------

func test_and_short_circuits_on_false() -> void:
	# false && <anything> should not evaluate the right side.
	# We can't observe this directly but at least confirm it returns false
	# and doesn't crash when right side would fail (unbound collection).
	var result := _disp.eval_condition("false && Fn.unbound.Nonexistent()")
	assert_false(result)

func test_or_short_circuits_on_true() -> void:
	var result := _disp.eval_condition("true || Fn.unbound.Nonexistent()")
	assert_true(result)


# ---------------------------------------------------------------------------
# Argument passing
# ---------------------------------------------------------------------------

func test_bool_literal_arg_passed() -> void:
	_disp.eval_condition("Fn.global.RecordArgs(true, false)")
	assert_eq(_fn.last_call_args, [true, false])

func test_int_literal_arg_passed() -> void:
	_disp.eval_condition("Fn.global.RecordArgs(42, 0)")
	assert_eq(_fn.last_call_args, [42, 0])

func test_string_literal_arg_passed() -> void:
	_disp.eval_condition('Fn.global.RecordArgs("hello", "world")')
	assert_eq(_fn.last_call_args, ["hello", "world"])

func test_var_ref_arg_is_var_ref_type() -> void:
	_vars.set_variable("health", 99)
	_disp.eval_condition("Fn.global.RecordArgs(Var.player.health, true)")
	assert_true(_fn.last_call_args[0] is VarRef, "Var arg should be a VarRef, not an evaluated value")

func test_var_ref_get_value_returns_current_value() -> void:
	_vars.set_variable("health", 99)
	_disp.eval_condition("Fn.global.RecordArgs(Var.player.health, true)")
	var ref: VarRef = _fn.last_call_args[0]
	assert_eq(ref.get_value(), 99)

func test_var_ref_set_value_writes_back() -> void:
	_vars.set_variable("has_keycard", false)
	_disp.eval_condition("Fn.global.RecordArgs(Var.player.has_keycard, true)")
	var ref: VarRef = _fn.last_call_args[0]
	ref.set_value(true)
	assert_true(_vars.get_variable("has_keycard"))

func test_var_ref_get_value_null_when_missing() -> void:
	# Variable not set → get_value() returns null
	_disp.eval_condition("Fn.global.RecordArgs(Var.player.nonexistent, true)")
	var ref: VarRef = _fn.last_call_args[0]
	assert_null(ref.get_value())

func test_var_ref_name_and_collection() -> void:
	_disp.eval_condition("Fn.global.RecordArgs(Var.player.health, true)")
	var ref: VarRef = _fn.last_call_args[0]
	assert_eq(ref.name, "health")
	assert_eq(ref.collection, "player")

func test_var_ref_resolve_unwraps_var_ref() -> void:
	_vars.set_variable("health", 42)
	_disp.eval_condition("Fn.global.RecordArgs(Var.player.health, true)")
	var ref: VarRef = _fn.last_call_args[0]
	assert_eq(VarRef.resolve(ref), 42)

func test_var_ref_resolve_passes_through_plain_value() -> void:
	assert_eq(VarRef.resolve(99), 99)
	assert_eq(VarRef.resolve("hello"), "hello")
	assert_eq(VarRef.resolve(true), true)


# ---------------------------------------------------------------------------
# Ls resolution
# ---------------------------------------------------------------------------

func test_ls_ref_resolved_to_option_value() -> void:
	_disp.set_lists({
		"global/thresholds": [
			{"key": "easy",   "option_value": 1},
			{"key": "medium", "option_value": 3},
			{"key": "hard",   "option_value": 5},
		]
	})
	_disp.eval_condition("Fn.global.RecordArgs(Ls.global.thresholds.medium, true)")
	assert_eq(_fn.last_call_args[0], 3)

func test_ls_ref_missing_key_returns_null() -> void:
	_disp.set_lists({
		"global/thresholds": [{"key": "easy", "option_value": 1}]
	})
	_disp.eval_condition("Fn.global.RecordArgs(Ls.global.thresholds.nonexistent, true)")
	assert_null(_fn.last_call_args[0])

func test_ls_ref_missing_list_returns_null() -> void:
	# No lists seeded — _lists is empty by default
	_disp.eval_condition("Fn.global.RecordArgs(Ls.global.nosuchlist.key, true)")
	assert_null(_fn.last_call_args[0])


# ---------------------------------------------------------------------------
# eval_call — switch expressions
# ---------------------------------------------------------------------------

func test_eval_call_returns_string() -> void:
	var result: Variant = _disp.eval_call("Fn.global.ReturnString()")
	assert_eq(result, "pass")

func test_eval_call_returns_fail() -> void:
	var result: Variant = _disp.eval_call("Fn.global.ReturnFail()")
	assert_eq(result, "fail")

func test_eval_call_empty_returns_empty_string() -> void:
	var result: Variant = _disp.eval_call("")
	assert_eq(result, "")


# ---------------------------------------------------------------------------
# AST caching — same expression parsed only once
# ---------------------------------------------------------------------------

func test_caching_does_not_change_result() -> void:
	# Call twice with the same expression — result must be identical.
	var r1 := _disp.eval_condition("Fn.global.AlwaysTrue()")
	var r2 := _disp.eval_condition("Fn.global.AlwaysTrue()")
	assert_eq(r1, r2)
	assert_true(r1)


# ---------------------------------------------------------------------------
# Return value passthrough
# ---------------------------------------------------------------------------

func test_fn_return_int_passthrough() -> void:
	var result: Variant = _disp.eval_call("Fn.global.ReturnArg(7)")
	assert_eq(result, 7)

func test_fn_return_string_passthrough() -> void:
	var result: Variant = _disp.eval_call('Fn.global.ReturnArg("hello")')
	assert_eq(result, "hello")


# ---------------------------------------------------------------------------
# has_call
# ---------------------------------------------------------------------------

func test_has_call_bound_function() -> void:
	assert_true(_disp.has_call("Fn.global.AlwaysTrue()"))

func test_has_call_unbound_collection() -> void:
	assert_false(_disp.has_call("Fn.unbound.SomeFunc()"))

func test_has_call_missing_method() -> void:
	assert_false(_disp.has_call("Fn.global.NoSuchMethod()"))


# ---------------------------------------------------------------------------
# eval_value — raw result without bool coercion
# ---------------------------------------------------------------------------

func test_eval_value_int_literal() -> void:
	assert_eq(_disp.eval_value("Fn.global.ReturnArg(42)"), 42)

func test_eval_value_string_literal() -> void:
	assert_eq(_disp.eval_value('Fn.global.ReturnArg("pass")'), "pass")


# ---------------------------------------------------------------------------
# card_ref — Card.CurrentContextCard resolution
# ---------------------------------------------------------------------------

func test_card_ref_resolves_to_context_card() -> void:
	var card := {"base_ref": "line", "data": {"line": "Hello"}}
	_disp.set_context_card(card)
	_disp.eval_condition("Fn.global.RecordArgs(Card.CurrentContextCard, true)")
	assert_eq(_fn.last_call_args[0], card)

func test_card_ref_empty_when_not_set() -> void:
	# Default context card is empty dict.
	_disp.eval_condition("Fn.global.RecordArgs(Card.CurrentContextCard, true)")
	assert_eq(_fn.last_call_args[0], {})


# ---------------------------------------------------------------------------
# Ls with "value" field format (new data model)
# ---------------------------------------------------------------------------

func test_ls_ref_resolved_with_value_field() -> void:
	_disp.set_lists({
		"global/thresholds": [
			{"key": "moderate", "value": 5.0},
		]
	})
	_disp.eval_condition("Fn.global.RecordArgs(Ls.global.thresholds.moderate, true)")
	assert_eq(_fn.last_call_args[0], 5.0)


# ---------------------------------------------------------------------------
# Bare Var.* used directly as a condition
#
# Var.* resolves to a VarRef object so that functions can write through it.
# A VarRef reaching a boolean context must be read first — plain bool() is true
# for any non-null Object, which used to make these conditions always pass.
# ---------------------------------------------------------------------------

func test_bare_var_condition_reads_the_variable() -> void:
	_vars.set_variable("flag", false)
	assert_false(_disp.eval_condition("Var.player.flag"),
		"a false variable must make the condition fail")

	_vars.set_variable("flag", true)
	assert_true(_disp.eval_condition("Var.player.flag"),
		"a true variable must make the condition pass")


func test_negated_bare_var_condition_reads_the_variable() -> void:
	_vars.set_variable("flag", false)
	assert_true(_disp.eval_condition("!Var.player.flag"))

	_vars.set_variable("flag", true)
	assert_false(_disp.eval_condition("!Var.player.flag"))


func test_bare_var_condition_combines_with_operators() -> void:
	_vars.set_variable("a", true)
	_vars.set_variable("b", false)

	assert_false(_disp.eval_condition("Var.player.a && Var.player.b"))
	assert_true(_disp.eval_condition("Var.player.a || Var.player.b"))


func test_bare_var_condition_treats_missing_variable_as_false() -> void:
	assert_false(_disp.eval_condition("Var.player.never_set"))


func test_bare_var_condition_coerces_non_bool_values() -> void:
	_vars.set_variable("count", 0)
	assert_false(_disp.eval_condition("Var.player.count"))

	_vars.set_variable("count", 3)
	assert_true(_disp.eval_condition("Var.player.count"))


func test_var_ref_still_reaches_functions_unresolved() -> void:
	# The fix must not resolve references on their way into a function, or
	# write-back bindings would break.
	_vars.set_variable("hp", 5)
	_disp.eval_condition("Fn.global.RecordArgs(Var.player.hp, true)")
	assert_true(_fn.last_call_args[0] is VarRef,
		"functions must still receive an unresolved VarRef")


func test_unbound_variable_collection_condition_is_false_not_a_crash() -> void:
	# bool() has no null constructor, so an unresolved value reaching a boolean
	# context used to raise instead of failing the condition.
	assert_false(_disp.eval_condition("Var.unbound_collection.thing"))
	assert_false(_disp.eval_condition("Ent.unbound_collection.thing"))
	assert_push_error_count(2, "each unbound collection is reported once")
