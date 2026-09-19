extends Node

const TarinoiApiImporterClass := preload("res://addons/tarinoi/core/api_importer.gd")

enum State { IDLE, NPC_LINE, PC_CHOICE, AWAITING_PIN }

# Dialogue signals
signal line_ready(line_data: Dictionary)
signal choices_ready(choices: Array)
signal dialogue_ended()
signal dialogue_error(message: String)
signal choice_made(card_data: Dictionary)
signal pin_choice_needed(pin_names: Array)

# Sync signals forwarded from importer
signal sync_started()
signal sync_completed(stats: Dictionary)
signal sync_failed(reason: String)
signal sync_progress(message: String, fraction: float)

## Bind game function and variable collections here before calling configure().
var registry: BindingRegistry = BindingRegistry.new()

## Data provider for all runtime queries. Assign a custom TarinoiDataAccess
## subclass before configure() to swap the backend. Defaults to TarinoiDataAccess.Sync.
## Also available after configure() for non-dialogue document access.
var data: TarinoiDataAccess = null

## Assign a TarinoiHistoryStore to enable seen-card tracking across dialogue
## visits. If null, seen state is not tracked: all choices carry visited=false
## and shown_once has no effect. See addons/tarinoi/core/history_store.gd.
var history_store: TarinoiHistoryStore = null

var _state: State = State.IDLE
var _db: TarinoiDB = null
var _dispatcher: Dispatcher = null
var _project_id: String = ""
var _current_collection_id: String = ""
var _current_card_data: Dictionary = {}  # keys: card, card_id, collection_id
var _choices: Array = []                 # Array of choice dicts (includes "card" key)
var _visited: Dictionary = {}            # card_id → true; loop detection within one traversal
var _api_importer: RefCounted = null
var _poll_timer: Timer = null
var _sync_in_progress: bool = false

# Seen-card history for the active dialogue session.
var _session_start_card_id: String = ""
# card_id → true; every line card actually shown to the player (NPC lines on display,
# PC lines on selection), seeded from history_store on start and flushed back on end.
var _session_visited_choices: Dictionary = {}

# System line queue — messages enqueued during output_selector evaluation that are
# presented as interstitial NPC lines the player advances through before the next card.
var _pending_system_lines: Array = []   # Array[String]
var _pending_nav_target: String = ""    # card_id to follow after advancing past system line

# In-memory global caches — layer-merged views of all non-card documents.
# Populated by _load_global_cache() on configure() and after every sync.
var _collections: Dictionary = {}          # collection_id → {label, collection_type, payload}
var _entities: Dictionary = {}             # entity identifier → payload Dictionary
var _lists: Dictionary = {}                # "col_name/list_id" → Array of option dicts
var _cache_max_update_key: int = 0         # highest update_key seen; tracks cache freshness


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Configure the runtime. The project is identified by tarinoi/api/path in
## Project Settings; open the local database and build the content caches.
func configure() -> void:
	var api_path := ProjectSettings.get_setting("tarinoi/api/path", "") as String
	if api_path.is_empty():
		TarinoiLogger.error("TarinoiRuntime: tarinoi/api/path not set in ProjectSettings — set it via Project Settings > Tarinoi, and set your API token via Tools > Tarinoi: Set Tarinoi API token…")
		return
	_project_id = api_path.trim_suffix("/").trim_suffix("/documents").get_file()

	if _project_id.is_empty():
		TarinoiLogger.error("TarinoiRuntime: cannot derive a project id from tarinoi/api/path '%s'" % api_path)
		return
	if _is_offline():
		_seed_db_from_bundle(_project_id)
	_db = TarinoiDB.new()
	if not _db.open(_project_id):
		TarinoiLogger.error("TarinoiRuntime: failed to open DB for project '%s'" % _project_id)
		_db = null
		return
	_dispatcher = Dispatcher.new(registry)
	_load_global_cache()
	if data == null:
		var provider_path := ProjectSettings.get_setting("tarinoi/data_provider", "") as String
		if not provider_path.is_empty():
			var cls = load(provider_path)
			if cls:
				data = cls.new()
			else:
				TarinoiLogger.error("TarinoiRuntime: failed to load data_provider '%s'" % provider_path)
		if data == null:
			data = TarinoiDataAccess.Sync.new()
	data._setup(_db, self)


func sync() -> void:
	if _is_offline():
		sync_completed.emit({})
		return
	_sync_api()


func _sync_api(poll: bool = false) -> void:
	if _sync_in_progress:
		return
	var api_path := ProjectSettings.get_setting("tarinoi/api/path", "") as String
	if api_path.is_empty():
		TarinoiLogger.error("TarinoiRuntime: tarinoi/api/path not set in ProjectSettings — set it via Project Settings > Tarinoi, and set your API token via Tools > Tarinoi: Set Tarinoi API token…")
		return
	_sync_in_progress = true
	_api_importer = TarinoiApiImporterClass.new()
	_api_importer.sync_started.connect(func():
		if poll:
			TarinoiLogger.debug("TarinoiRuntime: API poll sync started")
		else:
			TarinoiLogger.info("TarinoiRuntime: API sync started")
		sync_started.emit()
	)
	_api_importer.sync_completed.connect(func(stats: Dictionary):
		var upserted := stats.get("documents_upserted", 0) as int
		var deleted  := stats.get("documents_deleted",  0) as int
		if upserted > 0 or deleted > 0:
			TarinoiLogger.info("TarinoiRuntime: API sync complete — %d upserted, %d deleted" % [upserted, deleted])
		elif poll:
			TarinoiLogger.debug("TarinoiRuntime: API poll sync complete — no changes")
		else:
			TarinoiLogger.info("TarinoiRuntime: API sync complete — no changes")
		_sync_in_progress = false
		sync_completed.emit(stats)
		_load_global_cache()
		_start_poll_timer()
	)
	_api_importer.sync_failed.connect(func(reason: String):
		TarinoiLogger.error("TarinoiRuntime: API sync failed — " + reason)
		_sync_in_progress = false
		sync_failed.emit(reason)
		_start_poll_timer()
	)
	_api_importer.sync_progress.connect(func(msg: String, frac: float): sync_progress.emit(msg, frac))
	_api_importer.sync(api_path)


func _start_poll_timer() -> void:
	var poll_enabled := ProjectSettings.get_setting("tarinoi/api/poll_enabled", false) as bool
	var interval     := ProjectSettings.get_setting("tarinoi/api/poll_interval", 10) as int
	if not poll_enabled or interval <= 0:
		return
	if not is_instance_valid(_poll_timer):
		_poll_timer = Timer.new()
		_poll_timer.one_shot = false
		_poll_timer.timeout.connect(func(): _sync_api(true))
		add_child(_poll_timer)
		TarinoiLogger.info("TarinoiRuntime: API polling started — every %d s" % interval)
	_poll_timer.wait_time = float(interval)
	_poll_timer.start()


func _exit_tree() -> void:
	if is_instance_valid(_poll_timer) and not _poll_timer.is_stopped():
		TarinoiLogger.info("TarinoiRuntime: API polling stopped")


func start_dialogue(collection_id: String, card_id: String) -> void:
	if not _is_db_open():
		return
	_state = State.IDLE
	_current_collection_id = collection_id
	_visited.clear()
	_session_start_card_id = card_id
	_session_visited_choices = {}
	if history_store != null:
		for visited_id in history_store.get_visited(card_id):
			_session_visited_choices[visited_id] = true
	_load_and_process_card(collection_id, card_id)


func advance() -> void:
	if _state != State.NPC_LINE:
		TarinoiLogger.warn("TarinoiRuntime: advance() called in state %s" % _state_name())
		return
	# System lines (card_id == "__system__") use _pending_nav_target for navigation.
	if _current_card_data.get("card_id", "") == "__system__":
		var target := _pending_nav_target
		_pending_nav_target = ""
		_state = State.IDLE
		_load_and_process_card(_current_collection_id, target)
		return
	var card := _current_card_data["card"] as Dictionary
	var card_id := _current_card_data["card_id"] as String
	var col_id := _current_card_data["collection_id"] as String
	_state = State.IDLE
	_follow_connections(card, card_id, col_id)


func select_choice(index: int) -> void:
	if _state != State.PC_CHOICE:
		TarinoiLogger.warn("TarinoiRuntime: select_choice() called in state %s" % _state_name())
		return
	if index < 0 or index >= _choices.size():
		TarinoiLogger.warn("TarinoiRuntime: select_choice index %d out of range (0..%d)" % [index, _choices.size() - 1])
		return
	var chosen: Dictionary = _choices[index]
	var card := chosen["card"] as Dictionary
	var card_id := chosen["card_id"] as String
	var col_id := chosen["collection_id"] as String
	_state = State.IDLE
	_choices = []
	_session_visited_choices[card_id] = true
	_eval_card_functions(card, card_id)
	choice_made.emit(_make_line_data(card, card_id, col_id))
	_follow_connections(card, card_id, col_id)


func select_pin(pin_name: String) -> void:
	if _state != State.AWAITING_PIN:
		TarinoiLogger.warn("TarinoiRuntime: select_pin() called in state %s" % _state_name())
		return
	var card := _current_card_data["card"] as Dictionary
	var card_id := _current_card_data["card_id"] as String
	var col_id := _current_card_data["collection_id"] as String
	var target_id := _connection_target_for_pin(card, pin_name)
	if target_id.is_empty():
		TarinoiLogger.error("TarinoiRuntime: pin '%s' not found in card %s" % [pin_name, card_id])
		dialogue_error.emit("Pin '%s' not found in card %s" % [pin_name, card_id])
		return
	_state = State.IDLE
	_load_and_process_card(col_id, target_id)


func get_state() -> String:
	return _state_name()


## Evaluates any Tarinoi expression and returns the raw value (not coerced to bool).
## Useful for evaluating sub-expressions (e.g. list references) from function implementations.
func eval_expression(expr: String) -> Variant:
	if _dispatcher == null:
		return null
	return _dispatcher.eval_value(expr)


## Queues a system line to be presented as an interstitial NPC line.
## Called by function implementations (e.g. CheckSkill) during output_selector evaluation.
## The line appears after the current card's line and before the navigation target,
## requiring the player to advance past it.
func post_system_line(text: String) -> void:
	_pending_system_lines.append(text)


func abort_dialogue() -> void:
	_choices = []
	_visited.clear()
	_finish_dialogue()


## Returns all start cards sorted by collection label.
## Each dict: {card_id, collection_id, collection_label, label}
func get_start_cards() -> Array:
	if not _is_db_open():
		return []
	var rows: Array = await data.query_start_cards(_db.active_filter())
	var result: Array = []
	for row in rows:
		var doc_id    := row["document_id"]  as String
		var col_id    := row["collection_id"] as String
		var raw_label  = row.get("label")
		var col_label := (_collections.get(col_id, {}) as Dictionary).get("label", col_id)
		var display_label: String = "Start"
		if raw_label != null and raw_label is String and not (raw_label as String).is_empty():
			display_label = raw_label as String
		result.append({
			"card_id":          doc_id,
			"collection_id":    col_id,
			"collection_label": col_label,
			"label":            "%s <%s>" % [display_label, doc_id],
		})
	result.sort_custom(func(a, b):
		return a["collection_label"] < b["collection_label"]
	)
	return result


# ---------------------------------------------------------------------------
# Card processing
# ---------------------------------------------------------------------------

func _load_and_process_card(collection_id: String, card_id: String) -> void:
	if _check_loop(card_id):
		return
	var card: Dictionary = await data.load_card(collection_id, card_id)
	if card.is_empty():
		dialogue_error.emit("Card not found: %s in %s" % [card_id, collection_id])
		return
	await _process_card(card, card_id, collection_id)


func _process_card(card: Dictionary, card_id: String, collection_id: String) -> void:
	var condition: String = _str(_dict(card, "input_pin").get("condition", ""))
	if not condition.is_empty():
		if "$" in condition:
			TarinoiLogger.warn("TarinoiRuntime: unfilled template in condition '%s' [input_pin card:%s] — treating as true" % [condition, card_id])
		else:
			TarinoiLogger.debug("Condition '%s' [input_pin card:%s]" % [condition, card_id])
			var passed := _dispatcher != null and _dispatcher.eval_condition(condition)
			TarinoiLogger.debug("  condition → %s" % passed)
			if not passed:
				await _follow_connections(card, card_id, collection_id)
				return

	var base_ref: String = _str(card.get("base_ref", ""))
	# Line cards evaluate their functions at a later stage (NPC: on display,
	# PC: on selection) so we don't fire them prematurely for choice candidates.
	if base_ref != "line":
		_eval_card_functions(card, card_id)
	match base_ref:
		"start":
			await _follow_connections(card, card_id, collection_id)
		"jump":
			await _follow_jump(card, card_id, collection_id)
		"blank":
			await _process_blank(card, card_id, collection_id)
		"line":
			_process_line(card, card_id, collection_id)
		_:
			TarinoiLogger.warn("TarinoiRuntime: unknown base_ref '%s' on card %s — traversing silently" % [base_ref, card_id])
			await _follow_connections(card, card_id, collection_id)


func _process_line(card: Dictionary, card_id: String, collection_id: String) -> void:
	# A spent shown_once card is not a valid continuation. Reaching one on its own is
	# the same dead end as a card whose input conditions all failed — end the dialogue
	# rather than show it, and report it the same way. Its functions do not run: the
	# player never saw it.
	if _is_spent_shown_once(card, card_id):
		TarinoiLogger.error(
			("TarinoiRuntime: card '%s' in '%s' is shown_once and has already been seen, " \
			+ "and nothing else continues from here — implicit dialogue end") \
			% [card_id, collection_id])
		_finish_dialogue()
		return

	var entity_name: String = _str(card.get("entity_ref", ""))
	var line_mode: String = _str(card.get("line_mode", "inherit"))

	var is_pc: bool
	if line_mode == "pc":
		is_pc = true
	elif line_mode == "npc":
		is_pc = false
	else:
		var entity := _resolve_entity(entity_name)
		is_pc = entity.get("is_player_character", false)

	if is_pc:
		# PC card reached singly — present as a single forced choice
		_choices = [{
			"index": 0,
			"card_id": card_id,
			"collection_id": collection_id,
			"entity_ref": entity_name,
			"line_mode": line_mode,
			"line": card.get("data", {}).get("line", ""),
			"data": card.get("data", {}),
			"card": card,
			"visited": _session_visited_choices.has(card_id),
		}]
		_state = State.PC_CHOICE
		_visited.clear()
		choices_ready.emit(_choices)
	else:
		_eval_card_functions(card, card_id)
		# An NPC line counts as seen the moment it is displayed; a PC line only
		# counts once the player picks it (see select_choice).
		_session_visited_choices[card_id] = true
		_state = State.NPC_LINE
		_current_card_data = {"card": card, "card_id": card_id, "collection_id": collection_id}
		_visited.clear()
		line_ready.emit(_make_line_data(card, card_id, collection_id))


func _process_blank(card: Dictionary, card_id: String, collection_id: String) -> void:
	await _follow_connections(card, card_id, collection_id)


# Called after user input (advance/select_choice) AND for transparent cards (blank/start/jump).
# Decision tree: named pins + output_selector → auto-route; named pins, no selector → AWAITING_PIN;
# single default → follow directly; multiple defaults → look-ahead and emit choices_ready.
func _follow_connections(card: Dictionary, card_id: String, collection_id: String) -> void:
	if _dispatcher != null:
		_dispatcher.set_context_card(card)

	var connections: Array = _arr(card, "connections")
	if connections.is_empty():
		TarinoiLogger.error("TarinoiRuntime: card '%s' in '%s' has no connections — implicit dialogue end" % [card_id, collection_id])
		_finish_dialogue()
		return

	# Separate targets by pin name
	var default_targets: Array = []
	var named_pins: Dictionary = {}   # pin_name → target_id (first wins)
	var seen: Dictionary = {}

	for conn in connections:
		var parts := (conn as String).split(">>")
		if parts.size() < 2:
			continue
		var pin := parts[0]
		var target := parts[1]
		if target == "flow:end":
			# Explicit end sentinel — treat this card as terminal.
			_finish_dialogue()
			return
		if pin == "default":
			if not seen.has(target):
				default_targets.append(target)
				seen[target] = true
		else:
			if not named_pins.has(pin):
				named_pins[pin] = target

	if not named_pins.is_empty():
		var output_selector: String = _str(card.get("output_selector", ""))
		if not output_selector.is_empty() and "$" in output_selector:
			TarinoiLogger.warn("TarinoiRuntime: unfilled template in output_selector '%s' [card:%s] — falling back to manual pin" % [output_selector, card_id])
		elif not output_selector.is_empty() and _dispatcher != null and _dispatcher.has_call(output_selector):
			TarinoiLogger.debug("output_selector '%s' [card:%s]" % [output_selector, card_id])
			var pin_name := str(_dispatcher.eval_call(output_selector))
			TarinoiLogger.debug("  output_selector → '%s'" % pin_name)
			var target_id: String = _str(named_pins.get(pin_name, ""))
			if target_id.is_empty():
				_pending_system_lines.clear()
				dialogue_error.emit("Switch mismatch on card %s: selector returned '%s'" % [card_id, pin_name])
				return
			# If the function queued system lines, present the first as an interstitial
			# NPC line; the player advances through it to reach the target card.
			if not _pending_system_lines.is_empty():
				_pending_nav_target = target_id
				var msg: String = _pending_system_lines[0]
				_pending_system_lines.clear()
				_state = State.NPC_LINE
				_current_card_data = {"card": {}, "card_id": "__system__", "collection_id": collection_id}
				line_ready.emit({
					"card_id": "__system__",
					"collection_id": collection_id,
					"entity_ref": "system",
					"entity_label": "",
					"line_mode": "system",
					"line": msg,
					"base_ref": "",
					"template_ref": "",
					"data": {},
				})
				return
			await _load_and_process_card(collection_id, target_id)
			return
		elif not output_selector.is_empty():
			TarinoiLogger.error("TarinoiRuntime: output_selector '%s' function not bound — falling back to manual pin" % output_selector)
		# No output_selector or function not bound — developer tooling fallback.
		_current_card_data = {"card": card, "card_id": card_id, "collection_id": collection_id}
		_state = State.AWAITING_PIN
		pin_choice_needed.emit(named_pins.keys())
		return

	# All connections are default pins.
	if default_targets.is_empty():
		TarinoiLogger.error("TarinoiRuntime: card '%s' in '%s' has connections but none resolved to a valid target — implicit dialogue end" % [card_id, collection_id])
		_finish_dialogue()
		return

	if default_targets.size() == 1:
		await _load_and_process_card(collection_id, default_targets[0])
		return

	# Multiple default targets: look-ahead and present as choices.
	await _build_choices_from_targets(default_targets, collection_id, card_id)


## True when the card is marked shown_once and the player has already seen it, which
## makes it ineligible both as a choice and as a continuation.
##
## == true rather than a truthiness test: an explicit null in the payload defeats
## Dictionary.get()'s default.
func _is_spent_shown_once(card: Dictionary, card_id: String) -> bool:
	return card.get("shown_once", false) == true and _session_visited_choices.has(card_id)


func _build_choices_from_targets(target_ids: Array, collection_id: String, source_card_id: String = "") -> void:
	_choices = []
	var line_candidates := 0
	var shown_once_filtered := 0
	for cid in target_ids:
		var ccard: Dictionary = await data.load_card(collection_id, cid)
		if ccard.is_empty():
			continue
		if _str(ccard.get("base_ref", "")) != "line":
			# Non-line card among choices: silently skip it as a selectable option.
			TarinoiLogger.warn("TarinoiRuntime: non-line card %s in choice list — skipped" % cid)
			continue
		line_candidates += 1
		# shown_once: drop a card the player has already seen. Checked before the
		# input condition so a spent option costs nothing to evaluate.
		if _is_spent_shown_once(ccard, cid):
			TarinoiLogger.debug("shown_once: card %s already seen — filtered from choices" % cid)
			shown_once_filtered += 1
			continue
		var cond: String = _str(_dict(ccard, "input_pin").get("condition", ""))
		if not cond.is_empty():
			if "$" in cond:
				TarinoiLogger.warn("TarinoiRuntime: unfilled template in condition '%s' [input_pin card:%s] — treating as true" % [cond, cid])
			else:
				TarinoiLogger.debug("Condition '%s' [input_pin card:%s]" % [cond, cid])
				var passed := _dispatcher != null and _dispatcher.eval_condition(cond)
				TarinoiLogger.debug("  condition → %s" % passed)
				if not passed:
					continue
		_choices.append({
			"index": _choices.size(),
			"card_id": cid,
			"collection_id": collection_id,
			"entity_ref": _str(ccard.get("entity_ref", "")),
			"line": _str(_dict(ccard, "data").get("line", "")),
			"data": _dict(ccard, "data"),
			"card": ccard,
			"visited": _session_visited_choices.has(cid),
		})

	if _choices.is_empty():
		# Every way of running out of continuations is reported the same way; only the
		# message differs, so the cause is identifiable.
		if shown_once_filtered > 0:
			TarinoiLogger.error(
				"TarinoiRuntime: no continuation from card %s — of %d candidate(s), %d were "
				% [source_card_id, line_candidates, shown_once_filtered]
				+ "already-seen shown_once cards and the rest failed their input conditions. "
				+ "Give the card a fallback option without shown_once if it must stay reachable.")
		elif line_candidates > 0:
			TarinoiLogger.error(
				"TarinoiRuntime: no continuation from card %s — all %d input condition(s) failed" \
				% [source_card_id, line_candidates])
		_finish_dialogue()
		return

	_sort_choices_by_geometry()

	# What kind of set this is decides how it is presented, as in in-app playback.
	# Any PC line makes it a choice set: the PC lines are offered to the player,
	# and an NPC line mixed in is an authoring error and is dropped. Otherwise it
	# is an NPC set, and only the first line whose condition passed is shown —
	# the conditions are how the author picks the line, not a menu.
	var pc_choices := _choices.filter(func(c: Dictionary) -> bool: return _is_pc_card(c["card"]))
	var npc_choices := _choices.filter(func(c: Dictionary) -> bool: return not _is_pc_card(c["card"]))
	if not pc_choices.is_empty():
		if not npc_choices.is_empty():
			TarinoiLogger.warn(
				"TarinoiRuntime: mixed PC/NPC choice set from card %s — %d NPC line(s) dropped" \
				% [source_card_id, npc_choices.size()])
		_choices = pc_choices
	else:
		if npc_choices.size() > 1:
			# Duplicate/missing input conditions: the later ones can never be reached.
			var seen_conds: Dictionary = {}
			for choice: Dictionary in npc_choices:
				var cond: String = _str(_dict(choice["card"] as Dictionary, "input_pin").get("condition", ""))
				if seen_conds.has(cond):
					TarinoiLogger.warn(
						"TarinoiRuntime: NPC lines with duplicate/empty condition '%s' from card %s — only the first will be reached" \
						% [cond, source_card_id])
					break
				seen_conds[cond] = true
			TarinoiLogger.debug("%d NPC lines passed from card %s — showing the first, %s"
				% [npc_choices.size(), source_card_id, npc_choices[0]["card_id"]])
		_choices = [npc_choices[0]]
	for i in _choices.size():
		(_choices[i] as Dictionary)["index"] = i

	if _choices.size() == 1:
		# Filtered down to one valid choice: follow it directly (no choice UI).
		var only: Dictionary = _choices[0]
		_choices = []
		await _load_and_process_card(collection_id, only["card_id"])
		return

	_state = State.PC_CHOICE
	_visited.clear()
	choices_ready.emit(_choices)


## Orders choices by ascending geo.y, per https://tarinoi.app/docs/plugins/writing_your_own.html §7 — authors
## express the intended display order by laying cards out vertically in the
## graph editor, so connection order is an implementation artifact.
##
## sort_custom() is not stable, so ties fall back to the original position and
## the ordering stays deterministic. "index" is reassigned afterwards because
## select_choice() indexes _choices positionally.
func _sort_choices_by_geometry() -> void:
	for i in _choices.size():
		(_choices[i] as Dictionary)["_source_order"] = i

	_choices.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ay := _card_geo_y(a["card"] as Dictionary)
		var by := _card_geo_y(b["card"] as Dictionary)
		if ay == by:
			return (a["_source_order"] as int) < (b["_source_order"] as int)
		return ay < by
	)

	for i in _choices.size():
		var choice := _choices[i] as Dictionary
		choice.erase("_source_order")
		choice["index"] = i


## Vertical position of a card in the authoring graph.
##
## Cards without usable geometry sort last rather than to 0.0: authored y values
## are routinely negative, so 0.0 would drop them into the middle of the list.
## Note that geo may be present with a null y, which Dictionary.get()'s default
## would not catch.
func _card_geo_y(card: Dictionary) -> float:
	var geo: Variant = card.get("geo")
	if not geo is Dictionary:
		return INF
	var y: Variant = (geo as Dictionary).get("y")
	if y is float or y is int:
		return float(y)
	return INF


## A jump's destination is its one card-link property, `data.target`: the target
## card's bare document id, with no collection component, and possibly on another
## board. Locate it by id, then continue there.
func _follow_jump(card: Dictionary, card_id: String, _collection_id: String) -> void:
	var jdata: Dictionary = _dict(card, "data")
	var target := _str(jdata.get("target", ""))
	if target.is_empty():
		dialogue_error.emit("Jump card %s has no target" % card_id)
		return
	if _check_loop(target):
		return
	var located: Dictionary = await data.locate_card(target)
	if located.is_empty():
		dialogue_error.emit("Jump card %s points at a card that does not exist: %s" % [card_id, target])
		return
	await _process_card(located["card"], target, _str(located["collection_id"]))


# ---------------------------------------------------------------------------
# Global cache (collections, entities, lists)
# ---------------------------------------------------------------------------

## Coerces a Variant to String, treating SQL NULL as "" (Dictionary.get()'s
## default only applies when the key is absent, not when its value is null).
static func _str(v: Variant) -> String:
	return str(v) if v != null else ""


## Reads a nested Dictionary field, treating a JSON `null` value the same as an
## absent key (Dictionary.get()'s default only applies when the key is absent).
## Card payload fields like "input_pin" are stored as explicit JSON null when
## the pin has no condition/function calls.
static func _dict(d: Dictionary, key: String) -> Dictionary:
	var v: Variant = d.get(key)
	return v as Dictionary if v is Dictionary else {}


## Array counterpart of [method _dict]: a JSON `null` value reads as an empty
## Array rather than propagating Nil into a typed variable.
static func _arr(d: Dictionary, key: String) -> Array:
	var v: Variant = d.get(key)
	return v as Array if v is Array else []


## Loads all non-card global documents into memory.  Called at configure() time
## and after every sync.
##
## The two-layer merge is applied by TarinoiDB.active_filter(), the same SQL the
## card queries use.  This used to be reimplemented in GDScript here, which drifted:
## the copy ignored tombstones and, more importantly, ignored committed_only — so
## previewing committed content still showed uncommitted entities, collections and
## lists.  Keep the merge in one place.
func _load_global_cache() -> void:
	if not _is_db_open():
		return
	_collections = {}
	_entities    = {}
	_lists       = {}
	_cache_max_update_key = 0

	# --- Collection manifests ---
	var col_rows := _db.query_rows(
		"SELECT d.document_id, d.collection_id, d.update_key, d.identifier, d.payload FROM documents d WHERE d.document_type = 'collection-manifest' AND %s" % _db.active_filter()
	)
	for row in col_rows:
		var p: Variant = JSON.parse_string(row["payload"] as String)
		if not p is Dictionary:
			continue
		var pd := p as Dictionary
		_collections[row["document_id"] as String] = {
			"label":           pd.get("label", ""),
			"collection_type": pd.get("collection_type", ""),
			"payload":         pd,
			"identifier":      _str(row.get("identifier", "")),
		}
		_cache_max_update_key = max(_cache_max_update_key, int(row.get("update_key", 0)))

	# API sync path: collection manifests are stored in the collections table, not as documents.
	# Fall back to that table when the documents query found nothing.
	if _collections.is_empty():
		var col_table_rows := _db.query_rows(
			"SELECT collection_id, collection_type, payload FROM collections"
		)
		for row in col_table_rows:
			var p: Variant = JSON.parse_string(row["payload"] as String)
			if not p is Dictionary:
				continue
			var pd := p as Dictionary
			_collections[row["collection_id"] as String] = {
				"label":           pd.get("label", ""),
				"collection_type": row["collection_type"] as String,
				"payload":         pd,
				"identifier":      _str(pd.get("identifier", "")),
			}

	# --- Entities ---
	var ent_rows := _db.query_rows(
		"SELECT d.document_id, d.collection_id, d.update_key, d.identifier, d.payload FROM documents d WHERE d.document_type = 'entity' AND %s" % _db.active_filter()
	)
	for row in ent_rows:
		var p: Variant = JSON.parse_string(row["payload"] as String)
		if not p is Dictionary:
			continue
		var pd := p as Dictionary
		var identifier := _str(row.get("identifier", ""))
		if not identifier.is_empty():
			_entities[identifier] = pd
		_cache_max_update_key = max(_cache_max_update_key, int(row.get("update_key", 0)))

	# --- Lists ---
	# collection_name (the Ls.* key) lives at payload.collection_name on list-collection manifests.
	var list_col_map: Dictionary = {}   # collection_id → collection_name
	for col_id in _collections:
		var col := _collections[col_id] as Dictionary
		if col.get("collection_type", "") == "list-collection":
			var pd := col.get("payload", {}) as Dictionary
			var col_name := pd.get("collection_name", col.get("identifier", "")) as String
			if not col_name.is_empty():
				list_col_map[col_id] = col_name

	if not list_col_map.is_empty():
		var ids: Array = list_col_map.keys()
		var marks := PackedStringArray()
		marks.resize(ids.size())
		for i in ids.size():
			marks[i] = "?"
		var list_rows := _db.query_rows(
			"SELECT d.document_id, d.collection_id, d.update_key, d.identifier, d.payload FROM documents d WHERE d.collection_id IN (%s) AND %s" % [",".join(marks), _db.active_filter()],
			ids
		)
		for row in list_rows:
			var p: Variant = JSON.parse_string(row["payload"] as String)
			if not p is Dictionary:
				continue
			var pd := p as Dictionary
			var col_name := list_col_map.get(row["collection_id"] as String, "") as String
			var list_id  := _str(row.get("identifier", ""))
			# list_options is the current field name; fall back to options for older data.
			var options: Variant = pd.get("list_options", pd.get("options", []))
			if not col_name.is_empty() and not list_id.is_empty() and options is Array:
				_lists[col_name + "/" + list_id] = options
			_cache_max_update_key = max(_cache_max_update_key, int(row.get("update_key", 0)))

	if _dispatcher != null:
		_dispatcher.set_lists(_lists)


# ---------------------------------------------------------------------------
# Entity resolution
# ---------------------------------------------------------------------------

func _resolve_entity(entity_name: String) -> Dictionary:
	if entity_name.is_empty():
		return {}
	return _entities.get(entity_name, {})


# ---------------------------------------------------------------------------
# Card function evaluation
# ---------------------------------------------------------------------------

## Evaluates all Fn.* call expressions found in card.data.
## card.props provides the evaluation order; any function expression not listed
## in props is evaluated last (props may omit newly added fields).
## Called when a card is "committed to": on transparent traversal, when an NPC
## line is shown, or when a PC choice is selected.
func _eval_card_functions(card: Dictionary, card_id: String) -> void:
	if _dispatcher == null:
		return
	var data: Dictionary = _dict(card, "data")
	if data.is_empty():
		return

	# Build a position index from props so we can sort correctly.
	var order: Dictionary = {}
	var props: Array = _arr(card, "props")
	for i in props.size():
		order[(props[i] as Dictionary).get("name", "")] = i

	# Collect every Fn.* string value in data, regardless of whether props lists it.
	var calls: Array = []
	for prop_name in data:
		var value: Variant = data[prop_name]
		if not value is String:
			continue
		var expr := value as String
		if not expr.begins_with("Fn."):
			continue
		calls.append({"name": prop_name, "expr": expr, "order": order.get(prop_name, 999999)})

	if calls.is_empty():
		return

	calls.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["order"] < b["order"])

	for call in calls:
		var expr: String = call["expr"]
		if "$" in expr:
			TarinoiLogger.warn("TarinoiRuntime: unfilled template '%s' on card '%s' (property '%s') — skipped" % [expr, card_id, call["name"]])
		elif _dispatcher.has_call(expr):
			TarinoiLogger.debug("Fn '%s' [property '%s' card:%s]" % [expr, call["name"], card_id])
			_dispatcher.eval_call(expr)
		else:
			TarinoiLogger.error("TarinoiRuntime: unbound function call '%s' on card '%s' (property '%s')" % [expr, card_id, call["name"]])


# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------

func _connection_target_for_pin(card: Dictionary, pin_name: String) -> String:
	for conn in card.get("connections", []):
		var parts := (conn as String).split(">>")
		if parts.size() >= 2 and parts[0] == pin_name:
			return parts[1]
	return ""


func _is_pc_card(card: Dictionary) -> bool:
	var mode := card.get("line_mode", "inherit") as String
	if mode == "pc":
		return true
	if mode == "npc":
		return false
	return _resolve_entity(card.get("entity_ref", "")).get("is_player_character", false)


# ---------------------------------------------------------------------------
# Loop detection
# ---------------------------------------------------------------------------

func _check_loop(card_id: String) -> bool:
	if _visited.has(card_id):
		dialogue_error.emit("Loop detected at card %s" % card_id)
		return true
	_visited[card_id] = true
	return false


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _make_line_data(card: Dictionary, card_id: String, collection_id: String) -> Dictionary:
	var entity_name: String = _str(card.get("entity_ref", ""))
	var entity := _resolve_entity(entity_name)
	return {
		"card_id": card_id,
		"collection_id": collection_id,
		"entity_ref": entity_name,
		"entity_label": entity.get("label", entity_name),
		"line_mode": card.get("line_mode", "inherit"),
		"line": card.get("data", {}).get("line", ""),
		"base_ref": card.get("base_ref", ""),
		"template_ref": card.get("template_ref", ""),
		"data": card.get("data", {}),
	}


func _is_db_open() -> bool:
	if _db == null:
		TarinoiLogger.error("TarinoiRuntime: not configured — call configure() first")
		return false
	return true


func _is_offline() -> bool:
	return ProjectSettings.get_setting("tarinoi/behaviour/offline_mode", false) \
		or OS.has_feature("tarinoi_offline")


func _seed_db_from_bundle(project_id: String) -> void:
	var src := "res://tarinoi/bundled/" + project_id + ".db"
	if not FileAccess.file_exists(src):
		TarinoiLogger.error("TarinoiRuntime: bundled DB not found at '%s' — run 'Tarinoi: Snapshot for Export' first" % src)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://tarinoi"))
	var bytes := FileAccess.get_file_as_bytes(src)
	var wf := FileAccess.open("user://tarinoi/" + project_id + ".db", FileAccess.WRITE)
	if wf == null:
		TarinoiLogger.error("TarinoiRuntime: failed to write seeded DB to user://tarinoi/%s.db" % project_id)
		return
	wf.store_buffer(bytes)


func _finish_dialogue() -> void:
	_state = State.IDLE
	if history_store != null and not _session_start_card_id.is_empty():
		history_store.save_visited(_session_start_card_id, _session_visited_choices.keys())
	dialogue_ended.emit()


func _state_name() -> String:
	match _state:
		State.IDLE: return "IDLE"
		State.NPC_LINE: return "NPC_LINE"
		State.PC_CHOICE: return "PC_CHOICE"
		State.AWAITING_PIN: return "AWAITING_PIN"
	return "UNKNOWN"
