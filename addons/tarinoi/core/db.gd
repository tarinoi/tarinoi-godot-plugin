class_name TarinoiDB
extends RefCounted

const DB_BASE_PATH := "user://tarinoi"

# Bump this when the schema changes incompatibly. _init_schema() drops and
# recreates affected tables when the stored version is lower than this value.
const SCHEMA_VERSION := 3

var _db: SQLite = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func open(project_id: String) -> bool:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(DB_BASE_PATH)
	)
	_db = SQLite.new()
	_db.path = DB_BASE_PATH + "/" + project_id + ".db"
	_db.verbosity_level = SQLite.QUIET
	if not _db.open_db():
		TarinoiLogger.error("TarinoiDB: failed to open '%s': %s" % [_db.path, _db.error_message])
		return false
	_db.query("PRAGMA journal_mode=WAL")
	_init_schema()
	return true


func close() -> void:
	if _db:
		_db.close_db()
		_db = null


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

func query_rows(sql: String, bindings: Array = []) -> Array:
	if not _run(sql, bindings):
		return []
	return _db.query_result.duplicate(true)


func execute(sql: String, bindings: Array = []) -> bool:
	return _run(sql, bindings)


# ---------------------------------------------------------------------------
# Metadata convenience
# ---------------------------------------------------------------------------

func read_meta(key: String) -> String:
	var rows := query_rows("SELECT value FROM metadata WHERE key = ?", [key])
	return rows[0]["value"] if rows.size() > 0 else ""


func write_meta(key: String, value: String) -> void:
	execute("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)", [key, value])


# ---------------------------------------------------------------------------
# Active-document filter
#
# Returns a SQL WHERE fragment (no leading AND) for use in queries that alias
# the documents table as "d".  The fragment enforces the correct layer-merge
# semantics based on the current project settings:
#
#   committed_only = true
#     → main layer only: what the author has committed
#
#   committed_only = false
#     → two-layer merge: buffer overrides main; inactive buffer suppresses main
# ---------------------------------------------------------------------------

func active_filter() -> String:
	var committed_only: bool = ProjectSettings.get_setting("tarinoi/behaviour/committed_only", false)
	if committed_only:
		return "d.layer_id = 'tarinoi:main-project-layer' AND d.is_tombstone = 0 AND d.is_archived = 0 AND d.is_moved = 0"
	return """(
      (d.layer_id = 'tarinoi:main-project-layer.buffer'
       AND d.is_tombstone = 0 AND d.is_archived = 0 AND d.is_moved = 0)
      OR
      (d.layer_id = 'tarinoi:main-project-layer'
       AND d.is_tombstone = 0 AND d.is_archived = 0 AND d.is_moved = 0
       AND NOT EXISTS (
         SELECT 1 FROM documents b
         WHERE b.document_id   = d.document_id
           AND b.collection_id = d.collection_id
           AND b.layer_id = 'tarinoi:main-project-layer.buffer'
       ))
    )"""


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _run(sql: String, bindings: Array) -> bool:
	var ok: bool = _db.query_with_bindings(sql, bindings) if bindings.size() > 0 \
		else _db.query(sql)
	if not ok:
		TarinoiLogger.error("TarinoiDB: %s\n→ %s" % [_db.error_message, sql])
	return ok


func _init_schema() -> void:
	# Ensure metadata table exists first so we can read/write the schema version.
	_db.query("""
		CREATE TABLE IF NOT EXISTS metadata (
			key   TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)
	""")

	# Check stored schema version and wipe incompatible tables when stale.
	var rows: Array = []
	if _db.query("SELECT value FROM metadata WHERE key = 'schema_version'"):
		rows = _db.query_result.duplicate(true)
	var stored_version := int(rows[0]["value"]) if rows.size() > 0 else 0
	if stored_version < SCHEMA_VERSION:
		_db.query("DROP TABLE IF EXISTS documents")
		_db.query("DROP TABLE IF EXISTS collections")
		execute("INSERT OR REPLACE INTO metadata (key, value) VALUES ('schema_version', ?)",
			[str(SCHEMA_VERSION)])

	_db.query("""
		CREATE TABLE IF NOT EXISTS documents (
			document_id   TEXT NOT NULL,
			collection_id TEXT NOT NULL,
			document_type TEXT NOT NULL,
			layer_id      TEXT NOT NULL,
			namespace     TEXT NOT NULL DEFAULT 'document',
			identifier    TEXT,
			update_key    INTEGER NOT NULL,
			is_tombstone  INTEGER NOT NULL DEFAULT 0,
			is_archived   INTEGER NOT NULL DEFAULT 0,
			is_moved      INTEGER NOT NULL DEFAULT 0,
			payload       TEXT NOT NULL,
			PRIMARY KEY (document_id, collection_id, layer_id)
		)
	""")
	_db.query("""
		CREATE INDEX IF NOT EXISTS idx_documents_collection
		ON documents (collection_id, document_type)
	""")
	_db.query("""
		CREATE INDEX IF NOT EXISTS idx_documents_update_key
		ON documents (update_key)
	""")
	_db.query("""
		CREATE INDEX IF NOT EXISTS idx_documents_identifier
		ON documents (identifier)
	""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS collections (
			collection_id   TEXT PRIMARY KEY,
			collection_name TEXT,
			collection_type TEXT NOT NULL,
			payload         TEXT NOT NULL
		)
	""")
