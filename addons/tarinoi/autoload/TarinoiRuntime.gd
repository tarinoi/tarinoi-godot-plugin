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
signal system_message(text: String)

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

## Assign a TarinoiHistoryStore to enable visited-choice tracking across
## dialogue visits. If null, visited state is not tracked and all choices
## carry visited=false. See addons/tarinoi/core/history_store.gd.
var history_store: TarinoiHistoryStore = null

var _state: State = State.IDLE
var _db: TarinoiDB = null
var _dispatcher: Dispatcher = null
var _project_id: String = ""
var _current_collection_id: String = ""
var _current_card_data: Dictionary = {}  # keys: card, card_id, collection_id
var _choices: Array = []                 # Array of choice dicts (includes "card" key)
var _visited: Dictionary = {}            # card_id → true; loop detection within one traversal
var _importer: TarinoiImporter = null
var _api_importer: RefCounted = null
var _poll_timer: Timer = null
var _sync_in_progress: bool = false

# Visited-choice history for the active dialogue session.
var _session_start_card_id: String = ""
var _session_visited_choices: Dictionary = {}  # card_id → true; player choices this session, flushed to history_store on end

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

## Configure the runtime.  Pass repo_url for Git sync, or leave empty to
## auto-detect the project from ProjectSettings (handles both sync sources).
func configure(repo_url: String = "") -> void:
	var sync_source := ProjectSettings.get_setting("tarinoi/sync_source", "git") as String
	if repo_url.is_empty() or sync_source == "api":
		if sync_source == "api":
			var api_path := ProjectSettings.get_setting("tarinoi/api/path", "") as String
			if api_path.is_empty():
				TarinoiLogger.error("TarinoiRuntime: tarinoi/api_path not set in ProjectSettings")
				return
			var stripped := api_path.trim_suffix("/").trim_suffix("/documents")
			_project_id = stripped.get_file()
		else:
			var url := repo_url if not repo_url.is_empty() \
				else ProjectSettings.get_setting("tarinoi/git/repo_url", "") as String
			_project_id = _slug_from_url(url)
			# If still empty and api_path is set, derive project_id from it.
			# Happens when sync_source is left at "git" but only API is configured.
			if _project_id.is_empty():
				var api_path := ProjectSettings.get_setting("tarinoi/api/path", "") as String
				if not api_path.is_empty():
					TarinoiLogger.warn("TarinoiRuntime: repo_url not set; deriving project_id from api_path. Set tarinoi/sync_source to 'api' in Project Settings.")
					_project_id = api_path.trim_suffix("/").trim_suffix("/documents").get_file()
	else:
		_project_id = _slug_from_url(repo_url)

	if _project_id.is_empty():
		TarinoiLogger.error("TarinoiRuntime: cannot derive project_id — set tarinoi/sync_source and either tarinoi/repo_url or tarinoi/api_path in Project Settings")
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
	var sync_source := ProjectSettings.get_setting("tarinoi/sync_source", "git") as String
	if sync_source == "api":
		_sync_api()
	else:
		var repo_url := ProjectSettings.get_setting("tarinoi/git/repo_url", "") as String
		if repo_url.is_empty():
			var api_path := ProjectSettings.get_setting("tarinoi/api/path", "") as String
			if not api_path.is_empty():
				TarinoiLogger.warn("TarinoiRuntime: sync_source='git' but repo_url is not set; switching to API sync. Set tarinoi/sync_source to 'api' in Project Settings.")
				_sync_api()
				return
		_sync_git()


func _sync_git() -> void:
	var repo_url := ProjectSettings.get_setting("tarinoi/git/repo_url", "") as String
	if repo_url.is_empty():
		TarinoiLogger.error("TarinoiRuntime: tarinoi/repo_url not set in ProjectSettings")
		return
	_importer = TarinoiImporter.new()
	_importer.sync_started.connect(func(): sync_started.emit())
	_importer.sync_completed.connect(func(stats: Dictionary):
		sync_completed.emit(stats)
		_load_global_cache()
	)
	_importer.sync_failed.connect(func(reason: String): sync_failed.emit(reason))
	_importer.sync_progress.connect(func(msg: String, frac: float): sync_progress.emit(msg, frac))
	_importer.sync(repo_url)


func _sync_api() -> void:
	if _sync_in_progress:
		return
	var api_path := ProjectSettings.get_setting("tarinoi/api/path", "") as String
	if api_path.is_empty():
		TarinoiLogger.error("TarinoiRuntime: tarinoi/api_path not set in ProjectSettings")
		return
	_sync_in_progress = true
	_api_importer = TarinoiApiImporterClass.new()
	_api_importer.sync_started.connect(func(): sync_started.emit())
	_api_importer.sync_completed.connect(func(stats: Dictionary):
		_sync_in_progress = false
		sync_completed.emit(stats)
		_load_global_cache()
		_start_poll_timer()
	)
	_api_importer.sync_failed.connect(func(reason: String):
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
		_poll_timer.timeout.connect(func(): sync())
		add_child(_poll_timer)
	_poll_timer.wait_time = float(interval)
	_poll_timer.start()


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
	var condition: String = card.get("input_pin", {}).get("condition", "")
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

	var base_ref: String = card.get("base_ref", "")
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
	var entity_name: String = card.get("entity_ref", "")
	var line_mode: String = card.get("line_mode", "inherit")

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

	var connections: Array = card.get("connections", [])
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
		var output_selector: String = card.get("output_selector", "")
		if not output_selector.is_empty() and "$" in output_selector:
			TarinoiLogger.warn("TarinoiRuntime: unfilled template in output_selector '%s' [card:%s] — falling back to manual pin" % [output_selector, card_id])
		elif not output_selector.is_empty() and _dispatcher != null and _dispatcher.has_call(output_selector):
			TarinoiLogger.debug("output_selector '%s' [card:%s]" % [output_selector, card_id])
			var pin_name := str(_dispatcher.eval_call(output_selector))
			TarinoiLogger.debug("  output_selector → '%s'" % pin_name)
			var target_id: String = named_pins.get(pin_name, "")
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


func _build_choices_from_targets(target_ids: Array, collection_id: String, source_card_id: String = "") -> void:
	_choices = []
	var line_candidates := 0
	for cid in target_ids:
		var ccard: Dictionary = await data.load_card(collection_id, cid)
		if ccard.is_empty():
			continue
		if ccard.get("base_ref", "") != "line":
			# Non-line card among choices: silently skip it as a selectable option.
			TarinoiLogger.warn("TarinoiRuntime: non-line card %s in choice list — skipped" % cid)
			continue
		line_candidates += 1
		var cond: String = ccard.get("input_pin", {}).get("condition", "")
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
			"entity_ref": ccard.get("entity_ref", ""),
			"line": ccard.get("data", {}).get("line", ""),
			"data": ccard.get("data", {}),
			"card": ccard,
			"visited": _session_visited_choices.has(cid),
		})

	if _choices.is_empty():
		if line_candidates > 0:
			TarinoiLogger.error(
				"TarinoiRuntime: no continuation from card %s — all %d input condition(s) failed" \
				% [source_card_id, line_candidates])
		_finish_dialogue()
		return

	# Mixed PC/NPC set detection.
	var pc_choices := _choices.filter(func(c: Dictionary) -> bool: return _is_pc_card(c["card"]))
	var npc_choices := _choices.filter(func(c: Dictionary) -> bool: return not _is_pc_card(c["card"]))
	if pc_choices.size() > 0 and npc_choices.size() > 0:
		TarinoiLogger.warn(
			"TarinoiRuntime: mixed PC/NPC choice set from card %s — %d NPC line(s) will be unreachable" \
			% [source_card_id, npc_choices.size()])

	# Duplicate/missing input conditions on NPC-only set.
	if pc_choices.is_empty() and npc_choices.size() > 1:
		var seen_conds: Dictionary = {}
		for choice: Dictionary in npc_choices:
			var cond: String = (choice["card"] as Dictionary).get("input_pin", {}).get("condition", "")
			if seen_conds.has(cond):
				TarinoiLogger.warn(
					"TarinoiRuntime: NPC lines with duplicate/empty condition '%s' from card %s — only the first will be reached" \
					% [cond, source_card_id])
				break
			seen_conds[cond] = true

	if _choices.size() == 1:
		# Filtered down to one valid choice: follow it directly (no choice UI).
		var only: Dictionary = _choices[0]
		_choices = []
		await _load_and_process_card(collection_id, only["card_id"])
		return

	_state = State.PC_CHOICE
	_visited.clear()
	choices_ready.emit(_choices)


func _follow_jump(card: Dictionary, card_id: String, _collection_id: String) -> void:
	var jdata: Dictionary = card.get("data", {})
	var target_col := jdata.get("target_collection_id", "") as String
	var target_card := jdata.get("target_card_id", "") as String
	if target_col.is_empty() or target_card.is_empty():
		dialogue_error.emit("Jump card %s has missing target" % card_id)
		return
	await _load_and_process_card(target_col, target_card)


# ---------------------------------------------------------------------------
# Global cache (collections, entities, lists)
# ---------------------------------------------------------------------------

## Loads all non-card global documents into memory with the two-layer merge
## applied.  Called at configure() time and after every sync.
func _load_global_cache() -> void:
	if not _is_db_open():
		return
	_collections = {}
	_entities    = {}
	_lists       = {}
	_cache_max_update_key = 0

	# --- Collection manifests ---
	var col_rows := _db.query_rows(
		"SELECT document_id, collection_id, layer_id, is_archived, is_moved, update_key, payload FROM documents WHERE document_type = 'collection-manifest'"
	)
	for row in _merge_layers(col_rows):
		var p: Variant = JSON.parse_string(row["payload"] as String)
		if not p is Dictionary:
			continue
		var pd := p as Dictionary
		_collections[row["document_id"] as String] = {
			"label":           pd.get("label", ""),
			"collection_type": pd.get("collection_type", ""),
			"payload":         pd,
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
			}

	# --- Entities ---
	var ent_rows := _db.query_rows(
		"SELECT document_id, collection_id, layer_id, is_archived, is_moved, update_key, payload FROM documents WHERE document_type = 'entity'"
	)
	for row in _merge_layers(ent_rows):
		var p: Variant = JSON.parse_string(row["payload"] as String)
		if not p is Dictionary:
			continue
		var pd := p as Dictionary
		var identifier := pd.get("identifier", "") as String
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
			var col_name := pd.get("collection_name", pd.get("identifier", "")) as String
			if not col_name.is_empty():
				list_col_map[col_id] = col_name

	if not list_col_map.is_empty():
		var ids: Array = list_col_map.keys()
		var marks := PackedStringArray()
		marks.resize(ids.size())
		for i in ids.size():
			marks[i] = "?"
		var list_rows := _db.query_rows(
			"SELECT document_id, collection_id, layer_id, is_archived, is_moved, update_key, payload FROM documents WHERE collection_id IN (%s)" % ",".join(marks),
			ids
		)
		for row in _merge_layers(list_rows):
			var p: Variant = JSON.parse_string(row["payload"] as String)
			if not p is Dictionary:
				continue
			var pd := p as Dictionary
			var col_name := list_col_map.get(row["collection_id"] as String, "") as String
			var list_id  := pd.get("identifier", "") as String
			# list_options is the current field name; fall back to options for older data.
			var options: Variant = pd.get("list_options", pd.get("options", []))
			if not col_name.is_empty() and not list_id.is_empty() and options is Array:
				_lists[col_name + "/" + list_id] = options
			_cache_max_update_key = max(_cache_max_update_key, int(row.get("update_key", 0)))

	if _dispatcher != null:
		_dispatcher.set_lists(_lists)


## For each (document_id, collection_id) pair in rows, returns the single
## "winning" row using the two-layer merge rule:
##   - active buffer overrides main
##   - inactive buffer (archived/moved) suppresses main — nothing returned
##   - no buffer present → return main if active
func _merge_layers(rows: Array) -> Array:
	var by_key: Dictionary = {}
	for row in rows:
		var key := (row["document_id"] as String) + "|" + (row["collection_id"] as String)
		if not by_key.has(key):
			by_key[key] = {}
		if (row.get("layer_id", "") as String).ends_with(".buffer"):
			by_key[key]["buf"] = row
		else:
			by_key[key]["main"] = row

	var result: Array = []
	for key in by_key:
		var pair    := by_key[key] as Dictionary
		var buf     := pair.get("buf",  {}) as Dictionary
		var main_row := pair.get("main", {}) as Dictionary
		if not buf.is_empty():
			if not buf.get("is_archived", false) and not buf.get("is_moved", false):
				result.append(buf)
			# else: inactive buffer is a suppression marker — main is hidden too
		elif not main_row.is_empty():
			if not main_row.get("is_archived", false) and not main_row.get("is_moved", false):
				result.append(main_row)
	return result


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
	var data: Dictionary = card.get("data", {})
	if data.is_empty():
		return

	# Build a position index from props so we can sort correctly.
	var order: Dictionary = {}
	var props: Array = card.get("props", [])
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
	var entity_name: String = card.get("entity_ref", "")
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


func _slug_from_url(repo_url: String) -> String:
	return repo_url.get_file().trim_suffix(".git")


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
