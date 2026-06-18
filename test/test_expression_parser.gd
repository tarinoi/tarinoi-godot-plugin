extends GutTest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _cond(expr: String) -> Variant:
	return ExpressionParser.parse_condition(expr)

func _call(expr: String) -> Dictionary:
	return ExpressionParser.parse_call(expr)

func _bool(v: bool) -> Dictionary:
	return {"type": "bool_literal", "value": v}

func _int(v: int) -> Dictionary:
	return {"type": "int_literal", "value": v}

func _float(v: float) -> Dictionary:
	return {"type": "float_literal", "value": v}

func _slit(v: String) -> Dictionary:
	return {"type": "string_literal", "value": v}

func _ref(prefix: String, col: String, name: String, key: String = "") -> Dictionary:
	return {"type": "ref", "prefix": prefix, "collection": col, "name": name, "key": key}

func _call_node(col: String, name: String, args: Array = []) -> Dictionary:
	return {"type": "call", "prefix": "Fn", "collection": col, "name": name, "args": args}


# ---------------------------------------------------------------------------
# Empty / trivial
# ---------------------------------------------------------------------------

func test_empty_condition_returns_null() -> void:
	assert_null(_cond(""), "empty string should be null (always-true)")

func test_whitespace_only_returns_null() -> void:
	assert_null(_cond("   "), "whitespace-only should be null")

func test_true_literal() -> void:
	assert_eq(_cond("true"), _bool(true))

func test_false_literal() -> void:
	assert_eq(_cond("false"), _bool(false))


# ---------------------------------------------------------------------------
# Negation
# ---------------------------------------------------------------------------

func test_not_true() -> void:
	assert_eq(_cond("!true"), {"type": "not", "operand": _bool(true)})

func test_not_false() -> void:
	assert_eq(_cond("!false"), {"type": "not", "operand": _bool(false)})

func test_double_not() -> void:
	var expected := {"type": "not", "operand": {"type": "not", "operand": _bool(true)}}
	assert_eq(_cond("!!true"), expected)


# ---------------------------------------------------------------------------
# Binary operators
# ---------------------------------------------------------------------------

func test_and() -> void:
	var result: Variant = _cond("true && false")
	assert_eq(result["type"], "and")
	assert_eq(result["left"], _bool(true))
	assert_eq(result["right"], _bool(false))

func test_or() -> void:
	var result: Variant = _cond("false || true")
	assert_eq(result["type"], "or")
	assert_eq(result["left"], _bool(false))
	assert_eq(result["right"], _bool(true))

func test_and_binds_tighter_than_or() -> void:
	# a || b && c  →  or(a, and(b, c))
	var result: Variant = _cond("true || false && true")
	assert_eq(result["type"], "or")
	assert_eq(result["left"], _bool(true))
	assert_eq(result["right"]["type"], "and")

func test_grouping_overrides_precedence() -> void:
	# (a || b) && c  →  and(or(a, b), c)
	var result: Variant = _cond("(true || false) && true")
	assert_eq(result["type"], "and")
	assert_eq(result["left"]["type"], "or")


# ---------------------------------------------------------------------------
# Function calls — no args
# ---------------------------------------------------------------------------

func test_simple_fn_call_no_args() -> void:
	var result: Variant = _cond("Fn.global.HasKeycard()")
	assert_eq(result, _call_node("global", "HasKeycard", []))

func test_fn_call_in_condition() -> void:
	var result: Variant = _cond("Fn.checks.ResolvePersuasion()")
	assert_eq(result["type"], "call")
	assert_eq(result["collection"], "checks")
	assert_eq(result["name"], "ResolvePersuasion")

func test_parse_call_entry_point() -> void:
	var result := _call("Fn.global.HasKeycard()")
	assert_eq(result, _call_node("global", "HasKeycard", []))


# ---------------------------------------------------------------------------
# Function call arguments
# ---------------------------------------------------------------------------

func test_fn_call_bool_arg() -> void:
	var result: Variant = _cond("Fn.global.Gate(true)")
	assert_eq(result["args"], [_bool(true)])

func test_fn_call_two_bool_args() -> void:
	var result: Variant = _cond("Fn.global.Gate(true, false)")
	assert_eq(result["args"], [_bool(true), _bool(false)])

func test_fn_call_int_arg() -> void:
	var result: Variant = _cond("Fn.checks.SkillCheck(3)")
	assert_eq(result["args"], [_int(3)])

func test_fn_call_float_arg() -> void:
	var result: Variant = _cond("Fn.checks.SkillCheck(1.5)")
	assert_eq(result["args"], [_float(1.5)])

func test_fn_call_string_arg() -> void:
	var result: Variant = _cond('Fn.global.Check("hello")')
	assert_eq(result["args"], [_slit("hello")])

func test_fn_call_var_ref_arg() -> void:
	var result: Variant = _cond("Fn.global.Check(Var.player.health)")
	assert_eq(result["args"], [_ref("Var", "player", "health")])

func test_fn_call_ent_ref_arg() -> void:
	var result: Variant = _cond("Fn.global.Check(Ent.major.sylvia)")
	assert_eq(result["args"], [_ref("Ent", "major", "sylvia")])

func test_fn_call_ls_ref_arg() -> void:
	var result: Variant = _cond("Fn.checks.SkillCheck(Ls.global.thresholds.easy)")
	assert_eq(result["args"], [_ref("Ls", "global", "thresholds", "easy")])

func test_fn_call_mixed_args() -> void:
	var result: Variant = _cond("Fn.checks.SkillCheck(Var.player.score, Ls.global.thresholds.medium)")
	assert_eq(result["args"].size(), 2)
	assert_eq(result["args"][0], _ref("Var", "player", "score"))
	assert_eq(result["args"][1], _ref("Ls", "global", "thresholds", "medium"))


# ---------------------------------------------------------------------------
# Standalone references (when used as call args only — not top-level)
# ---------------------------------------------------------------------------

func test_var_ref_parsed_as_arg() -> void:
	var result: Variant = _cond("Fn.checks.Check(Var.player.has_keycard)")
	assert_eq(result["args"][0]["prefix"], "Var")
	assert_eq(result["args"][0]["collection"], "player")
	assert_eq(result["args"][0]["name"], "has_keycard")
	assert_eq(result["args"][0]["key"], "")

func test_ls_ref_has_key() -> void:
	var result: Variant = _cond("Fn.checks.Check(Ls.global.thresholds.hard)")
	assert_eq(result["args"][0]["prefix"], "Ls")
	assert_eq(result["args"][0]["name"], "thresholds")
	assert_eq(result["args"][0]["key"], "hard")


# ---------------------------------------------------------------------------
# Compound expressions from SPEC-DEMO
# ---------------------------------------------------------------------------

func test_spec_demo_persuasion_condition() -> void:
	# Fn.global.HasKeycard() — a no-arg bool fn used as a condition
	var result: Variant = _cond("Fn.global.HasKeycard()")
	assert_eq(result["type"], "call")
	assert_eq(result["name"], "HasKeycard")
	assert_eq(result["args"].size(), 0)

func test_compound_and_two_calls() -> void:
	var result: Variant = _cond("Fn.global.MyGate(true) && Fn.global.MyGate(false)")
	assert_eq(result["type"], "and")
	assert_eq(result["left"]["type"], "call")
	assert_eq(result["right"]["type"], "call")
	assert_eq(result["left"]["args"][0]["value"], true)
	assert_eq(result["right"]["args"][0]["value"], false)

func test_negated_fn_call() -> void:
	var result: Variant = _cond("!Fn.global.HasKeycard()")
	assert_eq(result["type"], "not")
	assert_eq(result["operand"]["type"], "call")
	assert_eq(result["operand"]["name"], "HasKeycard")


# ---------------------------------------------------------------------------
# Whitespace tolerance
# ---------------------------------------------------------------------------

func test_extra_spaces_ignored() -> void:
	var result: Variant = _cond("  true  &&  false  ")
	assert_eq(result["type"], "and")

func test_no_spaces() -> void:
	var result: Variant = _cond("true&&false")
	assert_eq(result["type"], "and")


# ---------------------------------------------------------------------------
# Card references
# ---------------------------------------------------------------------------

func test_card_current_context_card_as_arg() -> void:
	var result: Variant = _cond("Fn.global.CheckSkill(Card.CurrentContextCard)")
	assert_eq(result["type"], "call")
	assert_eq(result["name"], "CheckSkill")
	assert_eq(result["args"].size(), 1)
	assert_eq(result["args"][0]["type"], "card_ref")
	assert_eq(result["args"][0]["name"], "CurrentContextCard")

func test_card_ref_parses_name() -> void:
	var result: Variant = _cond("Fn.global.DoThing(Card.CurrentContextCard)")
	var arg: Dictionary = result["args"][0]
	assert_eq(arg["type"], "card_ref")
	assert_eq(arg["name"], "CurrentContextCard")
