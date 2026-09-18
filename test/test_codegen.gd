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
	assert_true(out.contains("class TarinoiGlobalFunctions:"))
	assert_true(out.contains("class TarinoiChecksFunctions:"))

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
	assert_true(out.contains('push_error("TarinoiFunctions.TarinoiGlobalFunctions.GrantKeycard is not implemented")'))

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
	var checks_pos := out.find("class TarinoiChecksFunctions:")
	var global_pos := out.find("class TarinoiGlobalFunctions:")
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

func test_gen_variables_maps_collections_to_their_classes() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains('const COLLECTIONS := {\n\t"player": TarinoiPlayerVariables,\n}'))

func test_gen_variables_has_collection_class() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains("class TarinoiPlayerVariables:"))

func test_gen_variables_has_typed_fields() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains("var has_keycard: bool = false"))
	assert_true(out.contains("var persuasion_score: float = 0.0"))

func test_gen_variables_has_get_set_via_reflection() -> void:
	var out := _cg._gen_variables(_make_vars(), "")
	assert_true(out.contains("func get_variable(variable_name: String) -> Variant:"))
	assert_true(out.contains("return get(variable_name)"))
	assert_true(out.contains("func set_variable(variable_name: String, value: Variant) -> void:"))
	assert_true(out.contains("set(variable_name, value)"))

func test_gen_variables_string_default_is_quoted() -> void:
	var vars := {"player": [{"name": "player_name", "data_type": "string", "default_value": "Alex"}]}
	var out := _cg._gen_variables(vars, "")
	assert_true(out.contains('var player_name: String = "Alex"'))

func test_gen_variables_no_default_falls_back_to_type_zero_value() -> void:
	var vars := {"player": [{"name": "score", "data_type": "number", "default_value": null}]}
	var out := _cg._gen_variables(vars, "")
	assert_true(out.contains("var score: float = 0.0"))


# ---------------------------------------------------------------------------
# _gd_type / _gd_default_literal
# ---------------------------------------------------------------------------

func test_gd_type_mapping() -> void:
	assert_eq(TarinoiCodegen._gd_type("boolean"), "bool")
	assert_eq(TarinoiCodegen._gd_type("number"), "float")
	assert_eq(TarinoiCodegen._gd_type("string"), "String")
	assert_eq(TarinoiCodegen._gd_type("object"), "Variant")

func test_gd_default_literal_boolean() -> void:
	assert_eq(TarinoiCodegen._gd_default_literal("boolean", true), "true")
	assert_eq(TarinoiCodegen._gd_default_literal("boolean", false), "false")
	assert_eq(TarinoiCodegen._gd_default_literal("boolean", null), "false")

func test_gd_default_literal_number() -> void:
	assert_eq(TarinoiCodegen._gd_default_literal("number", 100), "100.0")
	assert_eq(TarinoiCodegen._gd_default_literal("number", null), "0.0")

func test_gd_default_literal_string_escapes_quotes() -> void:
	assert_eq(TarinoiCodegen._gd_default_literal("string", 'he said "hi"'), '"he said \\"hi\\""')


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
	assert_true(out.contains("class TarinoiGlobalLists:"))

func test_gen_lists_has_inner_class() -> void:
	var out := _cg._gen_lists(_make_lists(), "")
	assert_true(out.contains("class TarinoiThresholdsList:"))

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
	assert_true(out.contains("class TarinoiMajorEntities:"))
	assert_true(out.contains("class TarinoiProtagonistsEntities:"))

func test_gen_entities_has_uppercased_constants() -> void:
	var out := _cg._gen_entities(_make_ents(), "")
	assert_true(out.contains('const SYLVIA_WHISTLER = "sylvia_whistler"'))
	assert_true(out.contains('const IRMA = "irma"'))
	assert_true(out.contains('const PLAYER = "player"'))


# ---------------------------------------------------------------------------
# parse_classes_from_content
# ---------------------------------------------------------------------------

const SAMPLE_FUNCTIONS_FILE := """class_name TarinoiFunctions

class TarinoiGlobalFunctions:
\tfunc HasKeycard() -> Variant:
\t\tpush_error("not implemented")
\t\treturn false

\tfunc GrantKeycard() -> Variant:
\t\tpush_error("not implemented")
\t\treturn

class TarinoiChecksFunctions:
\tfunc SkillCheck(skill: Variant, threshold: Variant) -> Variant:
\t\tpush_error("not implemented")
\t\treturn false
"""

func test_parse_classes_finds_class_names() -> void:
	var parsed := _cg.parse_classes_from_content(SAMPLE_FUNCTIONS_FILE)
	assert_true(parsed.has("TarinoiGlobalFunctions"))
	assert_true(parsed.has("TarinoiChecksFunctions"))

func test_parse_classes_finds_method_names() -> void:
	var parsed := _cg.parse_classes_from_content(SAMPLE_FUNCTIONS_FILE)
	assert_true((parsed["TarinoiGlobalFunctions"] as Dictionary).has("HasKeycard"))
	assert_true((parsed["TarinoiGlobalFunctions"] as Dictionary).has("GrantKeycard"))
	assert_true((parsed["TarinoiChecksFunctions"] as Dictionary).has("SkillCheck"))

func test_parse_classes_counts_args() -> void:
	var parsed := _cg.parse_classes_from_content(SAMPLE_FUNCTIONS_FILE)
	assert_eq((parsed["TarinoiGlobalFunctions"] as Dictionary)["HasKeycard"], 0)
	assert_eq((parsed["TarinoiChecksFunctions"] as Dictionary)["SkillCheck"], 2)

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
	# File only has TarinoiGlobalFunctions, DB also has Checks → ERROR
	var partial := "class_name TarinoiFunctions\n\nclass TarinoiGlobalFunctions:\n\tfunc HasKeycard() -> Variant:\n\t\treturn false\n\tfunc GrantKeycard() -> Variant:\n\t\treturn\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", partial)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "missing class should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


func test_validate_functions_error_on_missing_method() -> void:
	# File has TarinoiGlobalFunctions class but missing GrantKeycard
	var partial := "class_name TarinoiFunctions\n\nclass TarinoiGlobalFunctions:\n\tfunc HasKeycard() -> Variant:\n\t\treturn false\n\nclass TarinoiChecksFunctions:\n\tfunc SkillCheck(skill: Variant, threshold: Variant) -> Variant:\n\t\treturn false\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", partial)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "missing method should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


func test_validate_functions_warning_on_obsolete_class() -> void:
	# File has an obsolete class not in DB → WARNING
	var content := _cg._gen_functions(_make_fns(), "")
	content += "\nclass TarinoiOldCollectionFunctions:\n\tfunc OldFn() -> Variant:\n\t\treturn null\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", content)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_eq(_cg._errors, [], "obsolete class should only warn, not error")
	assert_true(_cg._warnings.size() > 0, "obsolete class should produce warning")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


func test_validate_functions_error_on_arg_count_change() -> void:
	# File has SkillCheck with 1 arg, DB says 2 → ERROR
	var wrong_argc := "class_name TarinoiFunctions\n\nclass TarinoiGlobalFunctions:\n\tfunc HasKeycard() -> Variant:\n\t\treturn false\n\tfunc GrantKeycard() -> Variant:\n\t\treturn\n\nclass TarinoiChecksFunctions:\n\tfunc SkillCheck(skill: Variant) -> Variant:\n\t\treturn false\n"
	_write_temp_file(TEMP_DIR + "tarinoi_functions.gd", wrong_argc)
	_cg._validate_functions(_make_fns(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "arg count mismatch should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_functions.gd")


# ---------------------------------------------------------------------------
# parse_variables_from_content
# ---------------------------------------------------------------------------

const SAMPLE_VARIABLES_FILE := """class_name TarinoiVariables

class TarinoiPlayerVariables:
\tvar has_keycard: bool = false
\tvar persuasion_score: float = 0.0

\tfunc get_variable(variable_name: String) -> Variant:
\t\treturn get(variable_name)

\tfunc set_variable(variable_name: String, value: Variant) -> void:
\t\tset(variable_name, value)
"""

func test_parse_variables_finds_class_and_fields() -> void:
	var parsed := _cg.parse_variables_from_content(SAMPLE_VARIABLES_FILE)
	assert_true(parsed.has("TarinoiPlayerVariables"))
	assert_eq((parsed["TarinoiPlayerVariables"] as Dictionary)["has_keycard"], "bool")
	assert_eq((parsed["TarinoiPlayerVariables"] as Dictionary)["persuasion_score"], "float")

func test_parse_variables_empty_content() -> void:
	assert_eq(_cg.parse_variables_from_content(""), {})


# ---------------------------------------------------------------------------
# _validate_variables — error and warning detection
# ---------------------------------------------------------------------------

func test_validate_variables_no_errors_when_matching() -> void:
	var content := _cg._gen_variables(_make_vars(), "")
	_write_temp_file(TEMP_DIR + "tarinoi_variables.gd", content)
	_cg._validate_variables(_make_vars(), TEMP_DIR)
	assert_eq(_cg._errors, [], "matching file should produce no errors")
	assert_eq(_cg._warnings, [], "matching file should produce no warnings")
	_delete_temp_file(TEMP_DIR + "tarinoi_variables.gd")


func test_validate_variables_error_on_missing_variable() -> void:
	# File only has has_keycard, DB also declares persuasion_score → ERROR
	var partial := "class_name TarinoiVariables\n\nclass TarinoiPlayerVariables:\n\tvar has_keycard: bool = false\n"
	_write_temp_file(TEMP_DIR + "tarinoi_variables.gd", partial)
	_cg._validate_variables(_make_vars(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "missing variable should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_variables.gd")


func test_validate_variables_error_on_type_change() -> void:
	# File has persuasion_score typed as bool, DB says number (float) → ERROR
	var wrong_type := "class_name TarinoiVariables\n\nclass TarinoiPlayerVariables:\n\tvar has_keycard: bool = false\n\tvar persuasion_score: bool = false\n"
	_write_temp_file(TEMP_DIR + "tarinoi_variables.gd", wrong_type)
	_cg._validate_variables(_make_vars(), TEMP_DIR)
	assert_true(_cg._errors.size() > 0, "type mismatch should produce error")
	_delete_temp_file(TEMP_DIR + "tarinoi_variables.gd")


func test_validate_variables_warning_on_obsolete_variable() -> void:
	var content := _cg._gen_variables(_make_vars(), "")
	content = content.replace("\tfunc get_variable", "\tvar old_field: bool = false\n\tfunc get_variable")
	_write_temp_file(TEMP_DIR + "tarinoi_variables.gd", content)
	_cg._validate_variables(_make_vars(), TEMP_DIR)
	assert_eq(_cg._errors, [], "obsolete variable should only warn, not error")
	assert_true(_cg._warnings.size() > 0, "obsolete variable should produce warning")
	_delete_temp_file(TEMP_DIR + "tarinoi_variables.gd")


# ---------------------------------------------------------------------------
# _load_* against a real TarinoiDB — regression coverage for the
# collection-identifier resolution bug (collections.collection_name holds the
# display label, not the machine identifier; the real identifier lives on the
# collection's own collection-manifest document) and the list-spec field name
# bug ("list_options", not "options").
# ---------------------------------------------------------------------------

func _make_test_db() -> TarinoiDB:
	var db := TarinoiDB.new()
	assert_true(db.open("__test_codegen_load__"), "DB opened for test")
	return db


func _seed_document(db: TarinoiDB, doc_id: String, col_id: String, doc_type: String,
		identifier: Variant, payload: Dictionary) -> void:
	db.execute("""
		INSERT OR REPLACE INTO documents
		(document_id, collection_id, document_type, layer_id, namespace, identifier,
		 update_key, is_tombstone, is_archived, is_moved, payload)
		VALUES (?, ?, ?, 'tarinoi:main-project-layer', 'document', ?, 1, 0, 0, 0, ?)
	""", [doc_id, col_id, doc_type, identifier, JSON.stringify(payload)])


func test_load_functions_keys_by_manifest_identifier_not_label() -> void:
	var db := _make_test_db()
	_seed_document(db, "colGlobalFn", "colGlobalFn", "collection-manifest", "global",
		{"label": "Global functions", "collection_type": "function-collection"})
	_seed_document(db, "fn1", "colGlobalFn", "function-declaration", "CheckFlag",
		{"function_args": [], "function_returns": "boolean", "function_effect": "pure"})
	_cg._db = db
	var fns := _cg._load_functions()
	assert_true(fns.has("global"), "should key by collection-manifest identifier ('global'), not the display label")
	assert_eq((fns["global"] as Array).size(), 1)
	assert_eq((fns["global"] as Array)[0]["effect"], "pure", "effect is read from the payload's function_effect field")
	db.close()


func test_load_variables_keys_by_manifest_identifier_not_label() -> void:
	var db := _make_test_db()
	_seed_document(db, "colPlayer", "colPlayer", "collection-manifest", "player",
		{"label": "Player", "collection_type": "variable-collection"})
	_seed_document(db, "var1", "colPlayer", "variable-declaration", "has_keycard",
		{"data_type": "boolean", "default_value": false})
	_cg._db = db
	var vars := _cg._load_variables()
	assert_true(vars.has("player"), "should key by collection-manifest identifier ('player'), not the display label")
	assert_eq((vars["player"] as Array).size(), 1)
	db.close()


func test_load_lists_reads_list_options_field() -> void:
	var db := _make_test_db()
	_seed_document(db, "colGlobalLists", "colGlobalLists", "collection-manifest", "global",
		{"label": "Global lists", "collection_type": "list-collection"})
	_seed_document(db, "list1", "colGlobalLists", "list-spec", "skills",
		{"list_options": [{"key": "mechanics", "value": "mechanics"}], "options": []})
	_cg._db = db
	var lists := _cg._load_lists()
	assert_true(lists.has("global"))
	var options: Array = ((lists["global"] as Array)[0] as Dictionary)["options"]
	assert_eq(options.size(), 1, "should read list_options, not the unrelated legacy 'options' field")
	db.close()


func test_load_entities_keys_by_manifest_identifier_not_label() -> void:
	var db := _make_test_db()
	_seed_document(db, "colMajor", "colMajor", "collection-manifest", "major",
		{"label": "Major characters", "collection_type": "entity-collection"})
	_seed_document(db, "ent1", "colMajor", "entity", "sylvia_whistler",
		{"dialog_capable": true})
	_cg._db = db
	var ents := _cg._load_entities()
	assert_true(ents.has("major"), "should key by collection-manifest identifier ('major'), not the display label")
	db.close()
