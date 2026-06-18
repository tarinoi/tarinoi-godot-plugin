extends GutTest

var _cg: TarinoiCodegen


func before_each() -> void:
	_cg = TarinoiCodegen.new()


# ---------------------------------------------------------------------------
# Static helpers
# ---------------------------------------------------------------------------

func test_to_pascal_single_word() -> void:
	assert_eq(TarinoiCodegen._to_pascal("global"), "Global")

func test_to_pascal_snake_case() -> void:
	assert_eq(TarinoiCodegen._to_pascal("player_state"), "PlayerState")

func test_to_pascal_three_parts() -> void:
	assert_eq(TarinoiCodegen._to_pascal("my_cool_module"), "MyCoolModule")

func test_to_pascal_already_pascal() -> void:
	assert_eq(TarinoiCodegen._to_pascal("Global"), "Global")

func test_to_pascal_empty() -> void:
	assert_eq(TarinoiCodegen._to_pascal(""), "")

func test_default_return_boolean() -> void:
	assert_eq(TarinoiCodegen._default_return("boolean"), "false")

func test_default_return_number() -> void:
	assert_eq(TarinoiCodegen._default_return("number"), "0")

func test_default_return_string() -> void:
	assert_eq(TarinoiCodegen._default_return("string"), '""')

func test_default_return_void() -> void:
	assert_eq(TarinoiCodegen._default_return("void"), "")

func test_default_return_unknown_falls_back_to_null() -> void:
	assert_eq(TarinoiCodegen._default_return("object"), "null")
	assert_eq(TarinoiCodegen._default_return(""), "null")


# ---------------------------------------------------------------------------
# _fn_arg_names / _fn_arg_decls
# ---------------------------------------------------------------------------

func test_fn_arg_names_empty() -> void:
	assert_eq(_cg._fn_arg_names([]), "")

func test_fn_arg_names_single() -> void:
	assert_eq(_cg._fn_arg_names([{"arg_name": "flag"}]), "flag")

func test_fn_arg_names_multiple() -> void:
	var args := [{"arg_name": "skill"}, {"arg_name": "threshold"}]
	assert_eq(_cg._fn_arg_names(args), "skill, threshold")

func test_fn_arg_decls_empty() -> void:
	assert_eq(_cg._fn_arg_decls([]), "")

func test_fn_arg_decls_single() -> void:
	assert_eq(_cg._fn_arg_decls([{"arg_name": "flag"}]), "flag: Variant")

func test_fn_arg_decls_multiple() -> void:
	var args := [{"arg_name": "skill"}, {"arg_name": "threshold"}]
	assert_eq(_cg._fn_arg_decls(args), "skill: Variant, threshold: Variant")


# ---------------------------------------------------------------------------
# _gen_functions
# ---------------------------------------------------------------------------

func _make_fns() -> Dictionary:
	return {
		"global": [
			{"name": "HasKeycard", "args": [],                          "returns": "boolean", "effect": "pure"},
			{"name": "GrantKeycard", "args": [],                        "returns": "void",    "effect": "mutation"},
		],
		"checks": [
			{"name": "SkillCheck", "args": [{"arg_name": "skill"}, {"arg_name": "threshold"}],
			                        "returns": "boolean", "effect": "side-effect"},
		],
	}

func test_gen_functions_has_class_name() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	assert_true(out.contains("class_name TarinoiFunctions"))

func test_gen_functions_has_collection_class() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	assert_true(out.contains("class Global:"))
	assert_true(out.contains("class Checks:"))

func test_gen_functions_has_method_stubs() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	assert_true(out.contains("func HasKeycard() -> Variant:"))
	assert_true(out.contains("func GrantKeycard() -> Variant:"))
	assert_true(out.contains("func SkillCheck(skill: Variant, threshold: Variant) -> Variant:"))

func test_gen_functions_boolean_returns_false() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	# HasKeycard returns boolean → stub should return false
	assert_true(out.contains("return false"))

func test_gen_functions_void_has_no_return_value() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	# GrantKeycard returns void → no "return " line for it
	# Check the void stub ends with push_error then empty return line
	assert_true(out.contains('push_error("TarinoiFunctions.Global.GrantKeycard is not implemented")'))

func test_gen_functions_has_push_error() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	assert_true(out.contains("push_error("))

func test_gen_functions_has_arg_comment() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	assert_true(out.contains("## SkillCheck(skill, threshold) -> boolean"))

func test_gen_functions_empty_produces_class_name_only() -> void:
	var out := _cg._gen_functions({}, "")
	assert_true(out.contains("class_name TarinoiFunctions"))
	assert_false(out.contains("class "))

func test_gen_functions_classes_sorted_alphabetically() -> void:
	var out := _cg._gen_functions(_make_fns(), "")
	var checks_pos := out.find("class Checks:")
	var global_pos := out.find("class Global:")
	assert_true(checks_pos < global_pos, "classes should be sorted: Checks before Global")


# ---------------------------------------------------------------------------
# _gen_variables
# ---------------------------------------------------------------------------

func _make_vars() -> Dictionary:
	return {
		"player": [
			{"name": "has_keycard",      "data_type": "boolean", "default_value": false},
			{"name": "persuasion_score", "data_type": "number",  "default_value": 0},
		],
	}

func test_gen_variables_has_class_name() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains("class_name TarinoiVariables"))

func test_gen_variables_has_collection_class() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains("class Player:"))

func test_gen_variables_lists_variable_names_in_comments() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains("has_keycard"))
	assert_true(out.contains("persuasion_score"))

func test_gen_variables_has_get_set_stubs() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains("func get_variable(variable_name: String) -> Variant:"))
	assert_true(out.contains("func set_variable(variable_name: String, value: Variant) -> void:"))

func test_gen_variables_has_push_errors() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains('push_error("TarinoiVariables.Player.get_variable is not implemented")'))
	assert_true(out.contains('push_error("TarinoiVariables.Player.set_variable is not implemented")'))


# ---------------------------------------------------------------------------
# _gen_lists
# ---------------------------------------------------------------------------

func _make_lists() -> Dictionary:
	return {
		"global": [
			{
				"identifier": "thresholds",
				"options": [
					{"key": "easy",   "option_value": 1},
					{"key": "medium", "option_value": 3},
					{"key": "hard",   "option_value": 5},
				],
			},
		],
	}

func test_gen_lists_has_class_name() -> void:
	var out := _cg._gen_lists(_make_lists(), "")
	assert_true(out.contains("class_name TarinoiLists"))

func test_gen_lists_has_outer_class() -> void:
	var out := _cg._gen_lists(_make_lists(), "")
	assert_true(out.contains("class Global:"))

func test_gen_lists_has_inner_class() -> void:
	var out := _cg._gen_lists(_make_lists(), "")
	assert_true(out.contains("class Thresholds:"))

func test_gen_lists_has_constants() -> void:
	var out := _cg._gen_lists(_make_lists(), "")
	assert_true(out.contains('const EASY = "easy"'))
	assert_true(out.contains('const MEDIUM = "medium"'))
	assert_true(out.contains('const HARD = "hard"'))

func test_gen_lists_constant_value_is_key_not_option_value() -> void:
	# Constants hold the key string, not the resolved option_value (int).
	# The dispatcher resolves option_value from DB at runtime.
	var out := _cg._gen_lists(_make_lists(), "")
	assert_false(out.contains("= 1"), "should not embed option_value int in constant")


# ---------------------------------------------------------------------------
# _gen_entities
# ---------------------------------------------------------------------------

func _make_ents() -> Dictionary:
	return {
		"major": [
			{"identifier": "sylvia_whistler"},
			{"identifier": "irma"},
		],
		"protagonists": [
			{"identifier": "player"},
		],
	}

func test_gen_entities_has_class_name() -> void:
	var out := _cg._gen_entities(_make_ents(), "")
	assert_true(out.contains("class_name TarinoiEntities"))

func test_gen_entities_has_collection_classes() -> void:
	var out := _cg._gen_entities(_make_ents(), "")
	assert_true(out.contains("class Major:"))
	assert_true(out.contains("class Protagonists:"))

func test_gen_entities_has_uppercased_constants() -> void:
	var out := _cg._gen_entities(_make_ents(), "")
	assert_true(out.contains('const SYLVIA_WHISTLER = "sylvia_whistler"'))
	assert_true(out.contains('const IRMA = "irma"'))
	assert_true(out.contains('const PLAYER = "player"'))


# ---------------------------------------------------------------------------
# parse_classes_from_content
# ---------------------------------------------------------------------------

const SAMPLE_FUNCTIONS_FILE := """class_name TarinoiFunctions

class Global:
\tfunc HasKeycard() -> Variant:
\t\tpush_error("not implemented")
\t\treturn false

\tfunc GrantKeycard() -> Variant:
\t\tpush_error("not implemented")
\t\treturn

class Checks:
\tfunc SkillCheck(skill: Variant, threshold: Variant) -> Variant:
\t\tpush_error("not implemented")
\t\treturn false
"""

func test_parse_classes_finds_class_names() -> void:
	var parsed := _cg.parse_classes_from_content(SAMPLE_FUNCTIONS_FILE)
	assert_true(parsed.has("Global"))
	assert_true(parsed.has("Checks"))

func test_parse_classes_finds_method_names() -> void:
	var parsed := _cg.parse_classes_from_content(SAMPLE_FUNCTIONS_FILE)
	assert_true((parsed["Global"] as Dictionary).has("HasKeycard"))
	assert_true((parsed["Global"] as Dictionary).has("GrantKeycard"))
	assert_true((parsed["Checks"] as Dictionary).has("SkillCheck"))

func test_parse_classes_counts_args() -> void:
	var parsed := _cg.parse_classes_from_content(SAMPLE_FUNCTIONS_FILE)
	assert_eq((parsed["Global"] as Dictionary)["HasKeycard"], 0)
	assert_eq((parsed["Checks"] as Dictionary)["SkillCheck"], 2)

func test_parse_classes_empty_content() -> void:
	var parsed := _cg.parse_classes_from_content("")
	assert_eq(parsed, {})


# ---------------------------------------------------------------------------
# Validation — error and warning detection
# ---------------------------------------------------------------------------

func _write_temp_file(path: String, content: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	f.store_string(content)
	f.close()


func _delete_temp_file(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


const TEMP_DIR := "user://tarinoi_test_codegen/"


func test_validate_functions_no_errors_when_file_absent() -> void:
	# No generated file → validation passes silently
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_eq(_cg._errors, [])
	assert_eq(_cg._warnings, [])


func test_validate_functions_no_errors_when_matching() -> void:
	var content := _cg._gen_functions(_make_fns(), "")
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", content)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_eq(_cg._errors, [], "matching file should produce no errors")
	assert_eq(_cg._warnings, [], "matching file should produce no warnings")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


func test_validate_functions_error_on_missing_class() -> void:
	# File only has Global, DB also has Checks → ERROR
	var partial := "class_name TarinoiFunctions\n\nclass Global:\n\tfunc HasKeycard() -> Variant:\n\t\treturn false\n\tfunc GrantKeycard() -> Variant:\n\t\treturn\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", partial)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "missing class should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


func test_validate_functions_error_on_missing_method() -> void:
	# File has Global class but missing GrantKeycard
	var partial := "class_name TarinoiFunctions\n\nclass Global:\n\tfunc HasKeycard() -> Variant:\n\t\treturn false\n\nclass Checks:\n\tfunc SkillCheck(skill: Variant, threshold: Variant) -> Variant:\n\t\treturn false\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", partial)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "missing method should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


func test_validate_functions_warning_on_obsolete_class() -> void:
	# File has an OldCollection class not in DB → WARNING
	var content := _cg._gen_functions(_make_fns(), "")
	content += "\nclass OldCollection:\n\tfunc OldFn() -> Variant:\n\t\treturn null\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", content)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_eq(_cg._errors, [], "obsolete class should only warn, not error")
	assert_true(_cg._warnings.size() > 0, "obsolete class should produce warning")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


func test_validate_functions_error_on_arg_count_change() -> void:
	# File has SkillCheck with 1 arg, DB says 2 → ERROR
	var wrong_argc := "class_name TarinoiFunctions\n\nclass Global:\n\tfunc HasKeycard() -> Variant:\n\t\treturn false\n\tfunc GrantKeycard() -> Variant:\n\t\treturn\n\nclass Checks:\n\tfunc SkillCheck(skill: Variant) -> Variant:\n\t\treturn false\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", wrong_argc)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "arg count mismatch should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")
