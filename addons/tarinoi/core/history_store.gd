## Base class for seen-card history stores.
## Override in your game to provide save-file-backed persistence.
##
## Assign an instance to TarinoiRuntime.history_store before starting dialogue.
## If history_store is null, seen state is not tracked: choices always report
## visited=false and the shown_once card flag has no effect.
##
## The runtime holds this state only while a dialogue is running. It asks for a
## dialogue's seen cards on start_dialogue() and hands the updated set back when
## the dialogue ends, so nothing persists inside the plugin.
class_name TarinoiHistoryStore

## Return the array of previously seen card IDs for the dialogue that begins
## at start_card_id. Return an empty array if nothing is recorded yet.
func get_visited(start_card_id: String) -> Array:
	return []


## Persist the complete set of seen card IDs for start_card_id.
## Called by TarinoiRuntime when a dialogue ends or is aborted.
## visited_ids is the cumulative set for this entry point across all visits:
## every NPC line displayed and every PC line the player chose.
func save_visited(start_card_id: String, visited_ids: Array) -> void:
	pass


## Default in-memory implementation. State is lost when this object is freed
## (e.g. on scene restart). Suitable for within-session seen tracking
## without save-file persistence.
class InMemory extends TarinoiHistoryStore:
	var _store: Dictionary = {}

	func get_visited(start_card_id: String) -> Array:
		return _store.get(start_card_id, [])

	func save_visited(start_card_id: String, visited_ids: Array) -> void:
		_store[start_card_id] = visited_ids
