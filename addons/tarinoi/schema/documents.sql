-- Tarinoi plugin — SQLite schema reference
--
-- This file is documentation only. The schema is applied programmatically by
-- db.gd, which is the source of truth; keep the two in step when either changes.
-- Schema version: 3 (see TarinoiDB.SCHEMA_VERSION).

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
	-- layer_id is part of the key so a document's committed and uncommitted
	-- versions coexist. TarinoiDB.active_filter() merges them at query time.
	PRIMARY KEY (document_id, collection_id, layer_id)
);

CREATE INDEX IF NOT EXISTS idx_documents_collection
	ON documents (collection_id, document_type);

CREATE INDEX IF NOT EXISTS idx_documents_update_key
	ON documents (update_key);

CREATE INDEX IF NOT EXISTS idx_documents_identifier
	ON documents (identifier);

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
--   schema_version       Schema version this database was created at
--   project_id           Project identifier, derived from the sync source
--   api_path             Documents endpoint URL (API sync)
--   api_sync_cursor      update_key watermark for incremental sync (API sync)
--   repo_url             Remote URL, without credentials (Git sync)
--   last_synced_commit   SHA of the last successfully imported commit (Git sync)
