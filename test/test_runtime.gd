extends GutTest

## Dialogue state machine tests.
##
## TarinoiRuntime ships as an autoload, but these tests instantiate their own copy
## per test instead of touching the global one — the singleton carries dialogue
## state, caches and a DB handle, and leaking any of that between tests makes
## failures depend on run order.
##
## Cards come from a fake data provider so the tests are about traversal, not SQL.
## Entities and collections come from a real database, because that is the path
## _load_global_cache() actually exercises.

const RuntimeScript := preload("res://addons/tarinoi/autoload/TarinoiRuntime.gd")

const MAIN_LAYER := "tarinoi:main-project-layer"
const BUF_LAYER  := "tarinoi:main-project-layer.buffer"

var _runtime: Node
var _fake: FakeData
var _project_id: String

# Recorded signal payloads.
var _lines: Array = []
var _choice_sets: Array = []
var _choices_made: Array = []
var _errors: Array = []
var _pin_requests: Array = []
var _ended_count: int = 0


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

## Serves cards from memory. Mirrors TarinoiDataAccess.Sync's contract.
class FakeData extends TarinoiDataAccess:
	var cards: Dictionary = {}          # "collection/card" → payload Dictionary
	var start_card_rows: Array = []
	var loaded_ids: Array = []

	var _runtime_ref = null

	func _setup(_db: TarinoiDB, runtime: Node) -> void:
		_runtime_ref = runtime

	func add(card_id: String, card: Dictionary, collection_id: String = "col1") -> void:
		cards[collection_id + "/" + card_id] = card

	func load_card(collection_id: String, card_id: String) -> Dictionary:
		loaded_ids.append(card_id)
		return cards.get(collection_id + "/" + card_id, {})

	func get_document(document_id: String, collection_id: String = "") -> Dictionary:
		return load_card(collection_id if not collection_id.is_empty() else "col1", document_id)

	func get_entity(identifier: String) -> Dictionary:
		if _runtime_ref == null:
			return {}
		return _runtime_ref._entities.get(identifier, {})

	func query_start_cards(_active_filter: String) -> Array:
		return start_card_rows


## Records which functions ran, in order.
class SpyFunctions:
	var calls: Array = []
	var pin_to_return: String = "a"

	func True() -> bool:
		calls.append("True")
		return true

	func False() -> bool:
		calls.append("False")
		return false

	func Effect() -> void:
		calls.append("Effect")

	func First() -> void:
		calls.append("First")

	func Second() -> void:
		calls.append("Second")

	func PickPin() -> String:
		calls.append("PickPin")
		return pin_to_return


## Posts a system line, then routes — the CheckSkill pattern.
class SystemLineFunctions:
	var _runtime: Node
	var extra_lines: Array = []

	func _init(runtime: Node) -> void:
		_runtime = runtime

	func CheckSkill() -> String:
		_runtime.post_system_line("You rolled well.")
		for extra in extra_lines:
			_runtime.post_system_line(extra as String)
		return "success"


# ---------------------------------------------------------------------------
# Card builder
# ---------------------------------------------------------------------------

func _card(base_ref: String) -> Dictionary:
	return {"base_ref": base_ref, "data": {}, "connections": []}


func _line(text: String, mode: String = "npc") -> Dictionary:
	var c := _card("line")
	c["line_mode"] = mode
	c["data"] = {"line": text}
	return c


## Adds plain "default" connections to each target.
func _to(card: Dictionary, targets: Array) -> Dictionary:
	var conns: Array = []
	for t in targets:
		conns.append("default>>" + (t as String))
	card["connections"] = conns
	return card


func _geo(card: Dictionary, y: float) -> Dictionary:
	card["geo"] = {"x": 0.0, "y": y}
	return card


func _cond(card: Dictionary, condition) -> Dictionary:
	card["input_pin"] = null if condition == null else {"condition": condition}
	return card


## Marks a card as show-once, the flag authors set in Tarinoi.
func _once(card: Dictionary) -> Dictionary:
	card["shown_once"] = true
	return card


# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

func before_each() -> void:
	_project_id = "__test_runtime_%d__" % (Time.get_ticks_usec())

	# Point the runtime at a throwaway project. api/path is what configure() reads.
	ProjectSettings.set_setting("tarinoi/api/path",
		"https://example.invalid/api/v1/group/%s/documents" % _project_id)
	ProjectSettings.set_setting("tarinoi/behaviour/committed_only", false)

	_lines = []
	_choice_sets = []
	_choices_made = []
	_errors = []
	_pin_requests = []
	_ended_count = 0

	_fake = FakeData.new()
	_runtime = RuntimeScript.new()
	add_child_autofree(_runtime)
	_runtime.data = _fake

	_runtime.line_ready.connect(func(d: Dictionary): _lines.append(d))
	_runtime.choices_ready.connect(func(c: Array): _choice_sets.append(c))
	_runtime.choice_made.connect(func(d: Dictionary): _choices_made.append(d))
	_runtime.dialogue_error.connect(func(m: String): _errors.append(m))
	_runtime.pin_choice_needed.connect(func(p: Array): _pin_requests.append(p))
	_runtime.dialogue_ended.connect(func(): _ended_count += 1)


func after_each() -> void:
	if _runtime != null and _runtime._db != null:
		_runtime._db.close()
	_delete_test_db()
	ProjectSettings.set_setting("tarinoi/behaviour/committed_only", false)


func _delete_test_db() -> void:
	var base := ProjectSettings.globalize_path("user://tarinoi")
	for suffix: String in ["", "-wal", "-shm"]:
		var path: String = base + "/" + _project_id + ".db" + suffix
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


## Writes a document straight into the test database. Call before configure() —
## the caches are built during configure().
func _seed_document(document_type: String, identifier: String, payload: Dictionary,
		layer_id: String = MAIN_LAYER, document_id: String = "",
		collection_id: String = "col1", archived: bool = false) -> void:
	var db := TarinoiDB.new()
	assert_true(db.open(_project_id), "test DB should open")
	db.execute("""
		INSERT OR REPLACE INTO documents
		(document_id, collection_id, document_type, layer_id, namespace, identifier,
		 update_key, is_tombstone, is_archived, is_moved, payload)
		VALUES (?, ?, ?, ?, 'document', ?, 1, 0, ?, 0, ?)
	""", [
		document_id if not document_id.is_empty() else identifier,
		collection_id, document_type, layer_id, identifier,
		1 if archived else 0,
		JSON.stringify(payload),
	])
	db.close()


func _seed_entity(identifier: String, is_pc: bool, label: String = "",
		layer_id: String = MAIN_LAYER) -> void:
	_seed_document("entity", identifier, {
		"is_player_character": is_pc,
		"label": label if not label.is_empty() else identifier,
	}, layer_id)


func _configure() -> void:
	_runtime.configure()


func _bind_spy() -> SpyFunctions:
	var spy := SpyFunctions.new()
	_runtime.registry.bind_function_collection("g", spy)
	return spy


func _last_line() -> Dictionary:
	return _lines[-1] if _lines.size() > 0 else {}


func _choices() -> Array:
	return _choice_sets[-1] if _choice_sets.size() > 0 else []


func _lines_of(choices: Array) -> Array:
	return choices.map(func(c: Dictionary) -> String: return c["line"] as String)


# ---------------------------------------------------------------------------
# Basic playback
# ---------------------------------------------------------------------------

func test_npc_line_is_emitted_with_speaker_and_text() -> void:
	_seed_entity("narrator", false, "The Narrator")
	_configure()
	_fake.add("c1", _to(_line("Hello there"), ["flow:end"]))
	(_fake.cards["col1/c1"] as Dictionary)["entity_ref"] = "narrator"

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines.size(), 1)
	assert_eq(_last_line()["line"], "Hello there")
	assert_eq(_last_line()["entity_label"], "The Narrator")
	assert_eq(_runtime.get_state(), "NPC_LINE")


func test_missing_card_reports_an_error() -> void:
	_configure()
	_runtime.start_dialogue("col1", "nope")

	assert_eq(_errors.size(), 1)
	assert_string_contains(_errors[0], "nope")


# ---------------------------------------------------------------------------
# Transparent cards
# ---------------------------------------------------------------------------

func test_blank_card_is_traversed_without_being_shown() -> void:
	_configure()
	_fake.add("c1", _to(_card("blank"), ["c2"]))
	_fake.add("c2", _to(_line("Arrived"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines.size(), 1)
	assert_eq(_last_line()["line"], "Arrived")


func test_start_card_is_traversed_without_being_shown() -> void:
	_configure()
	_fake.add("c1", _to(_card("start"), ["c2"]))
	_fake.add("c2", _to(_line("Arrived"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_last_line()["line"], "Arrived")


func test_jump_card_moves_to_another_collection() -> void:
	_configure()
	var jump := _card("jump")
	jump["data"] = {"target_collection_id": "col2", "target_card_id": "far"}
	_fake.add("c1", jump)
	_fake.add("far", _to(_line("Elsewhere"), ["flow:end"]), "col2")

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_last_line()["line"], "Elsewhere")


# ---------------------------------------------------------------------------
# Ending
# ---------------------------------------------------------------------------

func test_flow_end_finishes_the_dialogue() -> void:
	_configure()
	_fake.add("c1", _to(_line("Bye"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	_runtime.advance()

	assert_eq(_ended_count, 1)
	assert_eq(_runtime.get_state(), "IDLE")


func test_card_with_no_connections_ends_the_dialogue() -> void:
	_configure()
	_fake.add("c1", _line("Dead end"))

	_runtime.start_dialogue("col1", "c1")
	_runtime.advance()

	assert_eq(_ended_count, 1)
	assert_push_error_count(1, "a miswired card is an error")


func test_abort_ends_the_dialogue() -> void:
	_configure()
	_fake.add("c1", _to(_line("Hi"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	_runtime.abort_dialogue()

	assert_eq(_ended_count, 1)


# ---------------------------------------------------------------------------
# Default connections and choices
# ---------------------------------------------------------------------------

func test_single_default_target_is_followed_silently() -> void:
	_configure()
	_fake.add("c1", _to(_line("One"), ["c2"]))
	_fake.add("c2", _to(_line("Two"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	_runtime.advance()

	assert_eq(_last_line()["line"], "Two")
	assert_eq(_choice_sets.size(), 0, "one continuation is not a choice")


func test_duplicate_default_targets_are_collapsed() -> void:
	_configure()
	var c1 := _line("One")
	c1["connections"] = ["default>>c2", "default>>c2"]
	_fake.add("c1", c1)
	_fake.add("c2", _to(_line("Two"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	_runtime.advance()

	assert_eq(_last_line()["line"], "Two")
	assert_eq(_choice_sets.size(), 0)


func test_several_default_targets_become_choices() -> void:
	_configure()
	_fake.add("c1", _to(_card("blank"), ["a", "b"]))
	_fake.add("a", _geo(_line("Option A", "pc"), 10.0))
	_fake.add("b", _geo(_line("Option B", "pc"), 20.0))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_choices().size(), 2)
	assert_eq(_runtime.get_state(), "PC_CHOICE")


# ---------------------------------------------------------------------------
# Choice ordering — the geo.y rule (https://tarinoi.app/docs/plugins/writing_your_own §7)
# ---------------------------------------------------------------------------

func test_choices_are_ordered_by_ascending_geo_y() -> void:
	_configure()
	_fake.add("c1", _to(_card("blank"), ["bottom", "top", "middle"]))
	_fake.add("top",    _geo(_line("Top", "pc"), -50.0))
	_fake.add("middle", _geo(_line("Middle", "pc"), 0.0))
	_fake.add("bottom", _geo(_line("Bottom", "pc"), 120.5))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines_of(_choices()), ["Top", "Middle", "Bottom"],
		"authors express reading order by vertical position, not connection order")


func test_negative_positions_sort_before_zero() -> void:
	# A "missing means 0.0" default would break this.
	_configure()
	_fake.add("c1", _to(_card("blank"), ["zero", "negative"]))
	_fake.add("zero",     _geo(_line("Zero", "pc"), 0.0))
	_fake.add("negative", _geo(_line("Negative", "pc"), -1000.0))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines_of(_choices()), ["Negative", "Zero"])


func test_cards_without_geometry_sort_last() -> void:
	_configure()
	_fake.add("c1", _to(_card("blank"), ["nogeo", "positioned"]))
	_fake.add("nogeo",      _line("No geometry", "pc"))
	_fake.add("positioned", _geo(_line("Positioned", "pc"), 500.0))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines_of(_choices()), ["Positioned", "No geometry"])


func test_equal_positions_keep_their_original_order() -> void:
	_configure()
	_fake.add("c1", _to(_card("blank"), ["first", "second"]))
	_fake.add("first",  _geo(_line("First", "pc"), 10.0))
	_fake.add("second", _geo(_line("Second", "pc"), 10.0))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines_of(_choices()), ["First", "Second"], "ordering must be deterministic")


func test_choice_indices_match_position_after_sorting() -> void:
	# select_choice() indexes positionally, so stale indices select the wrong line.
	_configure()
	_fake.add("c1", _to(_card("blank"), ["bottom", "top"]))
	_fake.add("top",    _to(_geo(_line("Top", "pc"), 0.0), ["flow:end"]))
	_fake.add("bottom", _to(_geo(_line("Bottom", "pc"), 100.0), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	var indices: Array = _choices().map(func(c: Dictionary) -> int: return c["index"] as int)
	assert_eq(indices, [0, 1])

	_runtime.select_choice(0)
	assert_eq(_choices_made[0]["line"], "Top", "index 0 must be the topmost choice")


# ---------------------------------------------------------------------------
# Conditions
# ---------------------------------------------------------------------------

func test_choice_whose_condition_fails_is_not_offered() -> void:
	_configure()
	_bind_spy()
	_fake.add("c1", _to(_card("blank"), ["a", "b", "c"]))
	_fake.add("a", _cond(_geo(_line("Allowed", "pc"), 0.0), "Fn.g.True()"))
	_fake.add("b", _cond(_geo(_line("Blocked", "pc"), 10.0), "Fn.g.False()"))
	_fake.add("c", _geo(_line("Also allowed", "pc"), 20.0))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines_of(_choices()), ["Allowed", "Also allowed"])


func test_card_whose_entry_condition_fails_is_stepped_over() -> void:
	_configure()
	_bind_spy()
	_fake.add("c1", _cond(_to(_line("Skipped"), ["c2"]), "Fn.g.False()"))
	_fake.add("c2", _to(_line("Reached"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines.size(), 1)
	assert_eq(_last_line()["line"], "Reached")


func test_unfilled_template_in_a_condition_is_treated_as_met() -> void:
	_configure()
	_fake.add("c1", _cond(_to(_line("Shown"), ["flow:end"]), "Fn.g.Check($placeholder)"))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_last_line()["line"], "Shown")
	assert_push_warning_count(1, "the unfilled template is reported")


func test_explicit_null_input_pin_is_treated_as_no_condition() -> void:
	# Dictionary.get()'s default does not apply to a key present with a null value.
	_configure()
	_fake.add("c1", _cond(_to(_line("Shown"), ["flow:end"]), null))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_last_line()["line"], "Shown")


func test_null_condition_in_input_pin_is_treated_as_no_condition() -> void:
	# input_pin is present but its condition is an explicit null.
	_configure()
	var card := _to(_line("Shown"), ["flow:end"])
	card["input_pin"] = {"condition": null}
	_fake.add("c1", card)

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_last_line()["line"], "Shown")


# ---------------------------------------------------------------------------
# Player vs non-player lines
# ---------------------------------------------------------------------------

func test_player_line_reached_alone_becomes_a_single_choice() -> void:
	_configure()
	_fake.add("c1", _to(_line("I speak", "pc"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines.size(), 0)
	assert_eq(_choices().size(), 1)
	assert_eq(_runtime.get_state(), "PC_CHOICE")


func test_inherited_mode_uses_the_entity_to_decide() -> void:
	_seed_entity("hero", true)
	_seed_entity("narrator", false)
	_configure()

	var hero_line := _to(_line("Mine", "inherit"), ["flow:end"])
	hero_line["entity_ref"] = "hero"
	var npc_line := _to(_line("Theirs", "inherit"), ["flow:end"])
	npc_line["entity_ref"] = "narrator"
	_fake.add("hero_line", hero_line)
	_fake.add("npc_line", npc_line)

	_runtime.start_dialogue("col1", "hero_line")
	assert_eq(_choices().size(), 1, "a player entity yields a choice")

	_runtime.start_dialogue("col1", "npc_line")
	assert_eq(_lines.size(), 1, "a non-player entity yields a line")


# ---------------------------------------------------------------------------
# Card functions
# ---------------------------------------------------------------------------

func test_functions_on_an_npc_line_run_when_it_is_shown() -> void:
	_configure()
	var spy := _bind_spy()
	var card := _to(_line("Hi"), ["flow:end"])
	(card["data"] as Dictionary)["effect"] = "Fn.g.Effect()"
	_fake.add("c1", card)

	_runtime.start_dialogue("col1", "c1")

	assert_eq(spy.calls, ["Effect"])


func test_functions_on_unchosen_options_never_run() -> void:
	# The reason line cards defer their functions: side effects must not fire for
	# options the player never picks.
	_configure()
	var spy := _bind_spy()
	_fake.add("c1", _to(_card("blank"), ["taken", "ignored"]))

	var taken := _to(_geo(_line("Taken", "pc"), 0.0), ["flow:end"])
	(taken["data"] as Dictionary)["effect"] = "Fn.g.First()"
	var ignored := _to(_geo(_line("Ignored", "pc"), 10.0), ["flow:end"])
	(ignored["data"] as Dictionary)["effect"] = "Fn.g.Second()"
	_fake.add("taken", taken)
	_fake.add("ignored", ignored)

	_runtime.start_dialogue("col1", "c1")
	assert_eq(spy.calls, [], "offering choices must have no side effects")

	_runtime.select_choice(0)
	assert_eq(spy.calls, ["First"])


func test_functions_run_in_the_props_declared_order() -> void:
	_configure()
	var spy := _bind_spy()
	var card := _to(_line("Hi"), ["flow:end"])
	card["data"] = {"second_prop": "Fn.g.Second()", "first_prop": "Fn.g.First()", "line": "Hi"}
	card["props"] = [{"name": "first_prop"}, {"name": "second_prop"}]
	_fake.add("c1", card)

	_runtime.start_dialogue("col1", "c1")

	assert_eq(spy.calls, ["First", "Second"], "authors sequence side effects deliberately")


func test_functions_missing_from_props_run_last() -> void:
	_configure()
	var spy := _bind_spy()
	var card := _to(_line("Hi"), ["flow:end"])
	card["data"] = {"undeclared": "Fn.g.Second()", "declared": "Fn.g.First()", "line": "Hi"}
	card["props"] = [{"name": "declared"}]
	_fake.add("c1", card)

	_runtime.start_dialogue("col1", "c1")

	assert_eq(spy.calls, ["First", "Second"])


# ---------------------------------------------------------------------------
# Named pins and output selectors
# ---------------------------------------------------------------------------

func test_output_selector_routes_to_the_named_pin() -> void:
	_configure()
	var spy := _bind_spy()
	spy.pin_to_return = "success"

	var card := _card("blank")
	card["output_selector"] = "Fn.g.PickPin()"
	card["connections"] = ["success>>good", "failure>>bad"]
	_fake.add("c1", card)
	_fake.add("good", _to(_line("Succeeded"), ["flow:end"]))
	_fake.add("bad", _to(_line("Failed"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_last_line()["line"], "Succeeded")


func test_selector_returning_an_unknown_pin_stalls() -> void:
	_configure()
	var spy := _bind_spy()
	spy.pin_to_return = "nonexistent"

	var card := _card("blank")
	card["output_selector"] = "Fn.g.PickPin()"
	card["connections"] = ["success>>good", "failure>>bad"]
	_fake.add("c1", card)

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_errors.size(), 1)
	assert_eq(_ended_count, 0, "stalling is not ending — the mistake stays visible")
	assert_eq(_lines.size(), 0)


func test_named_pins_with_no_selector_ask_for_the_pin() -> void:
	_configure()
	var card := _card("blank")
	card["connections"] = ["a>>x", "b>>y"]
	_fake.add("c1", card)

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_runtime.get_state(), "AWAITING_PIN")
	assert_eq(_pin_requests.size(), 1)


func test_selecting_a_pin_follows_it() -> void:
	_configure()
	var card := _card("blank")
	card["connections"] = ["a>>x", "b>>y"]
	_fake.add("c1", card)
	_fake.add("y", _to(_line("Down path b"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	_runtime.select_pin("b")

	assert_eq(_last_line()["line"], "Down path b")


func test_duplicate_named_pins_keep_the_first_target() -> void:
	_configure()
	var card := _card("blank")
	card["connections"] = ["a>>first", "a>>second"]
	_fake.add("c1", card)
	_fake.add("first", _to(_line("First"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	_runtime.select_pin("a")

	assert_eq(_last_line()["line"], "First")


# ---------------------------------------------------------------------------
# System lines
# ---------------------------------------------------------------------------

func test_posted_system_line_is_shown_before_the_routed_card() -> void:
	_configure()
	_runtime.registry.bind_function_collection("g", SystemLineFunctions.new(_runtime))

	var card := _card("blank")
	card["output_selector"] = "Fn.g.CheckSkill()"
	card["connections"] = ["success>>good"]
	_fake.add("c1", card)
	_fake.add("good", _to(_line("You made it"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")

	assert_eq(_lines.size(), 1)
	assert_eq(_last_line()["card_id"], "__system__")
	assert_eq(_last_line()["line_mode"], "system")
	assert_eq(_last_line()["line"], "You rolled well.")

	_runtime.advance()

	assert_eq(_last_line()["line"], "You made it")


func test_only_the_first_posted_system_line_is_shown() -> void:
	_configure()
	var fns := SystemLineFunctions.new(_runtime)
	fns.extra_lines = ["Second", "Third"]
	_runtime.registry.bind_function_collection("g", fns)

	var card := _card("blank")
	card["output_selector"] = "Fn.g.CheckSkill()"
	card["connections"] = ["success>>good"]
	_fake.add("c1", card)
	_fake.add("good", _to(_line("Arrived"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	_runtime.advance()

	assert_eq(_last_line()["line"], "Arrived", "queued extras are discarded")


# ---------------------------------------------------------------------------
# Loop detection
# ---------------------------------------------------------------------------

func test_loop_that_never_reaches_the_player_is_broken() -> void:
	_configure()
	_fake.add("a", _to(_card("blank"), ["b"]))
	_fake.add("b", _to(_card("blank"), ["a"]))

	_runtime.start_dialogue("col1", "a")

	assert_eq(_errors.size(), 1)
	assert_string_contains(_errors[0], "Loop detected")


func test_revisiting_a_card_across_turns_is_allowed() -> void:
	# The guard only catches looping without ever stopping for input.
	_configure()
	_fake.add("a", _to(_line("Again?"), ["b"]))
	_fake.add("b", _to(_line("Yes"), ["a"]))

	_runtime.start_dialogue("col1", "a")
	_runtime.advance()
	_runtime.advance()

	assert_eq(_lines.size(), 3)
	assert_eq(_last_line()["line"], "Again?")
	assert_eq(_errors.size(), 0)


# ---------------------------------------------------------------------------
# Input guards
# ---------------------------------------------------------------------------

func test_advancing_when_nothing_is_shown_is_ignored() -> void:
	_configure()
	_runtime.advance()

	assert_eq(_lines.size(), 0)
	assert_push_warning_count(1)


func test_out_of_range_choice_is_ignored() -> void:
	_configure()
	_fake.add("c1", _to(_line("Only option", "pc"), ["flow:end"]))
	_runtime.start_dialogue("col1", "c1")

	_runtime.select_choice(99)

	assert_eq(_choices_made.size(), 0)
	assert_eq(_runtime.get_state(), "PC_CHOICE", "the choice stays open")
	assert_push_warning_count(1)


# ---------------------------------------------------------------------------
# Visited-choice history
# ---------------------------------------------------------------------------

func test_previously_chosen_options_are_marked_visited() -> void:
	_configure()
	_runtime.history_store = TarinoiHistoryStore.InMemory.new()
	_fake.add("c1", _to(_line("Option", "pc"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")
	assert_false(_choices()[0]["visited"], "not seen yet")

	_runtime.select_choice(0)
	_runtime.advance()

	_runtime.start_dialogue("col1", "c1")
	assert_true(_choices()[0]["visited"], "the same option on a second visit")


func test_choices_are_not_marked_visited_without_a_history_store() -> void:
	_configure()
	_fake.add("c1", _to(_line("Option", "pc"), ["flow:end"]))

	_runtime.start_dialogue("col1", "c1")

	assert_false(_choices()[0]["visited"])


# ---------------------------------------------------------------------------
# shown_once
#
# A card carrying shown_once stops being a valid continuation once the player has
# seen it, so authors get "say this only once" without hand-rolling a flag per card.
# Spent among other options, it is simply dropped; spent as the only way forward, it
# dead-ends the dialogue like any other card with nowhere valid to go.
# ---------------------------------------------------------------------------

## Hub offering three player lines, the first of which is show-once and loops back.
func _seed_shown_once_hub(loop_target: String = "hub") -> void:
	_fake.add("hub", _to(_card("blank"), ["a", "b", "c"]))
	_fake.add("a", _to(_geo(_once(_line("Once only", "pc")), 0.0), [loop_target]))
	_fake.add("b", _to(_geo(_line("Again", "pc"), 1.0), ["hub"]))
	_fake.add("c", _to(_geo(_line("And again", "pc"), 2.0), ["hub"]))


func test_shown_once_option_disappears_once_the_player_takes_it() -> void:
	_configure()
	_seed_shown_once_hub()

	_runtime.start_dialogue("col1", "hub")
	assert_eq(_lines_of(_choices()), ["Once only", "Again", "And again"],
		"offered normally the first time")

	_runtime.select_choice(0)   # take it, loop back to the hub

	assert_eq(_lines_of(_choices()), ["Again", "And again"],
		"the spent option is filtered out")


func test_shown_once_survives_the_dialogue_through_the_history_store() -> void:
	_configure()
	_runtime.history_store = TarinoiHistoryStore.InMemory.new()
	_seed_shown_once_hub("flow:end")

	_runtime.start_dialogue("col1", "hub")
	_runtime.select_choice(0)   # take it; the dialogue ends and history is flushed

	_runtime.start_dialogue("col1", "hub")

	assert_eq(_lines_of(_choices()), ["Again", "And again"],
		"still filtered on a later visit")


func test_shown_once_resets_between_dialogues_without_a_history_store() -> void:
	_configure()
	_seed_shown_once_hub("flow:end")

	_runtime.start_dialogue("col1", "hub")
	_runtime.select_choice(0)

	_runtime.start_dialogue("col1", "hub")

	assert_eq(_lines_of(_choices()), ["Once only", "Again", "And again"],
		"nothing persists the seen set, so the card is offered again")


func test_shown_once_counts_an_npc_line_from_the_moment_it_is_displayed() -> void:
	_configure()
	# n1 plays as a plain line first, then turns up again as a candidate.
	_fake.add("start", _to(_card("blank"), ["n1"]))
	_fake.add("n1", _to(_geo(_once(_line("Greeting")), 0.0), ["hub"]))
	_fake.add("hub", _to(_card("blank"), ["n1", "n2", "n3"]))
	_fake.add("n2", _to(_geo(_line("Small talk"), 1.0), ["flow:end"]))
	_fake.add("n3", _to(_geo(_line("More small talk"), 2.0), ["flow:end"]))

	_runtime.start_dialogue("col1", "start")
	assert_eq(_last_line()["line"], "Greeting")

	_runtime.advance()   # through n1 to the hub

	assert_eq(_lines_of(_choices()), ["Small talk", "More small talk"],
		"a displayed NPC line counts as seen")


func test_a_spent_shown_once_card_reached_on_its_own_ends_the_dialogue() -> void:
	_configure()
	_runtime.history_store = TarinoiHistoryStore.InMemory.new()
	_fake.add("s1", _to(_card("blank"), ["a"]))
	_fake.add("a", _to(_once(_line("Only way through")), ["flow:end"]))

	_runtime.start_dialogue("col1", "s1")
	assert_eq(_last_line()["line"], "Only way through", "shown the first time")
	_runtime.advance()

	_lines = []
	_runtime.start_dialogue("col1", "s1")

	assert_eq(_lines.size(), 0, "not shown a second time")
	assert_eq(_ended_count, 2, "a spent card is no continuation at all — the dialogue ends")
	assert_push_error_count(1, "reported like any other dead end")


func test_dialogue_ends_when_every_candidate_is_a_spent_shown_once_card() -> void:
	_configure()
	_fake.add("hub", _to(_card("blank"), ["a", "b"]))
	_fake.add("a", _to(_geo(_once(_line("First", "pc")), 0.0), ["hub"]))
	_fake.add("b", _to(_geo(_once(_line("Second", "pc")), 1.0), ["hub"]))

	_runtime.start_dialogue("col1", "hub")
	_runtime.select_choice(0)     # "First" spent; only "Second" left, so it is forced
	_runtime.select_choice(0)     # "Second" spent; the hub now has nothing to offer

	assert_eq(_ended_count, 1, "the dialogue ends rather than hanging")
	assert_push_error_count(1, "reported like any other dead end")


# ---------------------------------------------------------------------------
# Global cache and the two-layer merge
#
# These cover the bug that motivated unifying the merge: _load_global_cache()
# used to reimplement it in GDScript, ignoring committed_only — so previewing
# committed content still showed uncommitted entities.
# ---------------------------------------------------------------------------

func test_entities_are_loaded_from_the_database() -> void:
	_seed_entity("narrator", false, "The Narrator")
	_configure()

	assert_eq((_runtime._entities.get("narrator", {}) as Dictionary).get("label"), "The Narrator")


func test_active_buffer_entity_overrides_main() -> void:
	_seed_entity("narrator", false, "Committed name", MAIN_LAYER)
	_seed_entity("narrator", false, "Edited name", BUF_LAYER)
	_configure()

	assert_eq((_runtime._entities.get("narrator", {}) as Dictionary).get("label"), "Edited name")


func test_archived_buffer_entity_suppresses_main() -> void:
	# An inactive buffer row is a deletion marker, not a revert.
	_seed_entity("narrator", false, "Committed name", MAIN_LAYER)
	_seed_document("entity", "narrator", {"label": "Deleted"}, BUF_LAYER, "", "col1", true)
	_configure()

	assert_false(_runtime._entities.has("narrator"),
		"an archived buffer row must hide the committed version")


func test_committed_only_hides_buffer_entities() -> void:
	# This is what the GDScript merge got wrong: it never read the setting, so
	# previewing committed content still showed uncommitted entities.
	_seed_entity("narrator", false, "Committed name", MAIN_LAYER)
	_seed_entity("narrator", false, "Edited name", BUF_LAYER)
	ProjectSettings.set_setting("tarinoi/behaviour/committed_only", true)
	_configure()

	assert_eq((_runtime._entities.get("narrator", {}) as Dictionary).get("label"), "Committed name",
		"committed_only must apply to entities, not just cards")


func test_committed_only_ignores_an_archived_buffer_marker() -> void:
	_seed_entity("narrator", false, "Committed name", MAIN_LAYER)
	_seed_document("entity", "narrator", {"label": "Deleted"}, BUF_LAYER, "", "col1", true)
	ProjectSettings.set_setting("tarinoi/behaviour/committed_only", true)
	_configure()

	assert_true(_runtime._entities.has("narrator"),
		"an uncommitted deletion must not affect the committed view")
