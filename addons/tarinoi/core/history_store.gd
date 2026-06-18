## Base class for visited-choice history stores.
## Override in your game to provide save-file-backed persistence.
##
## Assign an instance to TarinoiRuntime.history_store before starting dialogue.
## If history_store is null, visited state is not tracked.
class_name TarinoiHistoryStore

## Return the array of previously visited card IDs for the dialogue that begins
## at start_card_id. Return an empty array if nothing is recorded yet.
func get_visited(start_card_id: String) -> Array:
	return []


## Persist the complete set of visited choice card IDs for start_card_id.
## Called by TarinoiRuntime when a dialogue ends or is aborted.
## visited_ids is the cumulative set for this entry point across all visits.
func save_visited(start_card_id: String, visited_ids: Array) -> void:
	pass


## Default in-memory implementation. State is lost when this object is freed
## (e.g. on scene restart). Suitable for within-session visited tracking
## without save-file persistence.
class InMemory extends TarinoiHistoryStore:
	var _store: Dictionary = {}

	func get_visited(start_card_id: String) -> Array:
		return _store.get(start_card_id, [])

	func save_visited(start_card_id: String, visited_ids: Array) -> void:
		_store[start_card_id] = visited_ids
