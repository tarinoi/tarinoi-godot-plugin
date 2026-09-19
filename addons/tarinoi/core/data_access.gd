## Base class for Tarinoi data providers.
## Override to use a custom backend (e.g. worker-thread Sync, or an in-memory
## structure for testing). Assign to TarinoiRuntime.data before calling configure();
## if left null at configure() time, TarinoiDataAccess.Sync is used.
##
## Alternatively, set tarinoi/data_provider in ProjectSettings to a .gd script path
## and TarinoiRuntime will instantiate it automatically.
##
## configure() calls _setup() after the DB is open so implementations can capture
## any resources they need.
class_name TarinoiDataAccess


## Called by TarinoiRuntime.configure() after the DB is open.
## Override to capture the db/runtime references your implementation needs.
func _setup(db: TarinoiDB, runtime: Node) -> void:
	pass


## Return the active payload dict for document_id, or {} if not found.
func get_document(document_id: String, collection_id: String = "") -> Dictionary:
	return {}


## Return the entity payload dict for the given identifier, or {} if not found.
func get_entity(identifier: String) -> Dictionary:
	return {}


## Return the parsed payload dict for a card, or {} if not found.
func load_card(collection_id: String, card_id: String) -> Dictionary:
	return {}


## Find a card by document id alone, when the collection is not known — a jump's
## `data.target` is a bare document id and may point at another board.
## Return {"collection_id": String, "card": Dictionary}, or {} if not found.
func locate_card(card_id: String) -> Dictionary:
	return {}


## Return raw DB rows for all start cards (document_id, collection_id, priority), or [].
func query_start_cards(active_filter: String) -> Array:
	return []


## Default Sync-backed implementation. Used when no custom provider is assigned.
##
## To add async dispatch (e.g. worker-thread Sync), subclass this and override
## _query() to return a Signal that emits when the query completes. All accessor
## methods route through _query() automatically.
class Sync extends TarinoiDataAccess:
	var _db: TarinoiDB = null
	var _runtime = null  # TarinoiRuntime node


	func _setup(db: TarinoiDB, runtime: Node) -> void:
		_db = db
		_runtime = runtime


	## The async seam. By default, runs the query on the main thread and returns
	## immediately. To move queries off-thread: override this method, dispatch to
	## a worker, and await a completion Signal that emits the Array result — then
	## return that value. Because `await signal` evaluates to the emitted value,
	## the return type stays Array and all callers work unchanged.
	func _query(sql: String, params: Array = []) -> Array:
		if _db == null:
			return []
		return _db.query_rows(sql, params)


	func get_document(document_id: String, collection_id: String = "") -> Dictionary:
		if _db == null:
			return {}
		var sql: String
		var bindings: Array
		if collection_id.is_empty():
			sql = "SELECT d.payload FROM documents d WHERE d.document_id = ? AND %s" \
				% _db.active_filter()
			bindings = [document_id]
		else:
			sql = "SELECT d.payload FROM documents d WHERE d.document_id = ? AND d.collection_id = ? AND %s" \
				% _db.active_filter()
			bindings = [document_id, collection_id]
		var rows: Array = await _query(sql, bindings)
		if rows.is_empty():
			return {}
		var parsed: Variant = JSON.parse_string(rows[0]["payload"] as String)
		if parsed == null or not parsed is Dictionary:
			return {}
		return parsed as Dictionary


	func get_entity(identifier: String) -> Dictionary:
		if _runtime == null:
			return {}
		return _runtime._entities.get(identifier, {})


	func load_card(collection_id: String, card_id: String) -> Dictionary:
		if _db == null:
			return {}
		var rows: Array = await _query(
			"SELECT d.payload FROM documents d WHERE d.document_id = ? AND d.collection_id = ? AND %s" \
				% _db.active_filter(),
			[card_id, collection_id]
		)
		if rows.is_empty():
			return {}
		var parsed: Variant = JSON.parse_string(rows[0]["payload"] as String)
		if parsed == null or not parsed is Dictionary:
			return {}
		return parsed as Dictionary

	func locate_card(card_id: String) -> Dictionary:
		if _db == null:
			return {}
		var rows: Array = await _query(
			"SELECT d.collection_id, d.payload FROM documents d WHERE d.document_id = ? AND d.document_type = 'card' AND %s" \
				% _db.active_filter(),
			[card_id]
		)
		if rows.is_empty():
			return {}
		var parsed: Variant = JSON.parse_string(rows[0]["payload"] as String)
		if parsed == null or not parsed is Dictionary:
			return {}
		return {"collection_id": str(rows[0]["collection_id"]), "card": parsed as Dictionary}


	func query_start_cards(active_filter: String) -> Array:
		if _db == null:
			return []
		return await _query("""
			SELECT d.document_id, d.collection_id,
				   json_extract(d.payload, '$.data.label') AS label
			FROM documents d
			WHERE d.document_type = 'card'
			  AND json_extract(d.payload, '$.base_ref') = 'start'
			  AND %s
		""" % active_filter)
