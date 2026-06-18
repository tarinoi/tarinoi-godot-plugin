-- Tarinoi plugin — SQLite schema reference
-- Applied programmatically by db.gd; this file is for documentation only.

CREATE TABLE IF NOT EXISTS documents (
	document_id   TEXT NOT NULL,
	collection_id TEXT NOT NULL,
	document_type TEXT NOT NULL,
	layer_id      TEXT NOT NULL,
	namespace     TEXT NOT NULL DEFAULT 'document',
	slug          TEXT,
	update_key    INTEGER NOT NULL,
	is_tombstone  INTEGER NOT NULL DEFAULT 0,
	is_archived   INTEGER NOT NULL DEFAULT 0,
	is_moved      INTEGER NOT NULL DEFAULT 0,
	payload       TEXT NOT NULL,
	PRIMARY KEY (document_id, collection_id)
);

CREATE INDEX IF NOT EXISTS idx_documents_collection
	ON documents (collection_id, document_type);

CREATE INDEX IF NOT EXISTS idx_documents_update_key
	ON documents (update_key);

CREATE TABLE IF NOT EXISTS collections (
	collection_id   TEXT PRIMARY KEY,
	collection_name TEXT,
	collection_type TEXT NOT NULL,
	payload         TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS metadata (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);
-- Keys used in metadata (accessed via TarinoiDB.read_meta / write_meta):
--   last_synced_commit   SHA of the last successfully imported commit
--   project_id           Derived slug (repo URL basename)
--   repo_url             Remote URL (without credentials)
