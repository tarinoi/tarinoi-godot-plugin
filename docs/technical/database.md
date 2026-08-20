# Local Database

## Responsibility

The SQLite mirror of a project's Tarinoi documents, and the upsert rules the
importer applies to it. Writes run on a background thread. Nothing here is
called at dialogue runtime — sync is a discrete operation triggered by the game
or by an editor action.

How documents get here from the service is [`api-sync.md`](api-sync.md).

---

## SQLite Schema

One database file per project, stored at `user://tarinoi/<project_id>.db`.

### `documents`

The primary mirror of Tarinoi documents. Mirrors the `themis_documents`
envelope plus the raw JSON payload.

```sql
CREATE TABLE IF NOT EXISTS documents (
    document_id     TEXT NOT NULL,
    collection_id   TEXT NOT NULL,
    document_type   TEXT NOT NULL,
    layer_id        TEXT NOT NULL,
    namespace       TEXT NOT NULL DEFAULT 'document',
    slug            TEXT,
    update_key      INTEGER NOT NULL,
    is_tombstone    INTEGER NOT NULL DEFAULT 0,
    is_archived     INTEGER NOT NULL DEFAULT 0,
    is_moved        INTEGER NOT NULL DEFAULT 0,
    payload         TEXT NOT NULL,          -- raw JSON string
    PRIMARY KEY (document_id, collection_id, layer_id)
);

CREATE INDEX IF NOT EXISTS idx_documents_collection
    ON documents (collection_id, document_type);

CREATE INDEX IF NOT EXISTS idx_documents_update_key
    ON documents (update_key);
```

Active documents only: `WHERE is_tombstone = 0 AND is_archived = 0 AND is_moved = 0`.
The runtime always filters to active documents. The importer hard-deletes
tombstoned rows (see Tombstone Handling below).

### `collections`

Mirrors collection manifests.

```sql
CREATE TABLE IF NOT EXISTS collections (
    collection_id   TEXT PRIMARY KEY,
    collection_name TEXT,               -- collection_name from payload, may be null
    collection_type TEXT NOT NULL,      -- from payload.collection_type
    payload         TEXT NOT NULL       -- raw JSON string
);
```

### `metadata`

Plugin housekeeping.

```sql
CREATE TABLE IF NOT EXISTS metadata (
    key     TEXT PRIMARY KEY,
    value   TEXT NOT NULL
);
-- Keys used:
--   'api_sync_cursor'      update_key of the last document imported
--   'project_id'           Tarinoi project ID (set on first import)
--   'api_path'             Documents endpoint (set on first import)
```

---

## Upsert Logic

For each document in a sync page:

```
if document.is_tombstone OR document.is_archived OR document.is_moved:
    hard-delete from documents WHERE document_id = ? AND collection_id = ?
else:
    INSERT OR REPLACE INTO documents (...) VALUES (...)
```

Hard-delete on tombstone: the document is gone, no need to retain it.
This keeps the DB clean and the runtime query simple.

For collection documents: upsert the `collections` table row.

---

## Incremental Sync Cursor

After each successfully written page:

```sql
INSERT OR REPLACE INTO metadata (key, value) VALUES ('api_sync_cursor', '<update_key>');
```

On the next sync that value is sent back to the service, which returns only
documents changed since. If `api_sync_cursor` is absent, the sync is a full one:
every document in the project, paged from the beginning.

Because the cursor advances per page rather than per sync, an interrupted sync
resumes from the last page it wrote rather than starting over.

---

## Error Handling

| Condition | Behaviour |
|---|---|
| No API token saved | Emit `sync_failed("no api_key in credentials file")`, abort |
| Network or HTTP failure | Emit `sync_failed("<status/reason>")`, abort |
| Malformed JSON on an NDJSON line | Log a warning naming the line, skip it, continue |
| SQLite write error | Emit `sync_failed("db error: <message>")`, abort |
| Partial sync (some lines fail) | Emit `sync_completed` with `warnings` list |

`api_sync_cursor` only advances for a page written without a fatal error, so a
failure leaves it where the last good page left it and the next sync retries
from that point.

---

## Signals (emitted on main thread via call_deferred)

```gdscript
signal sync_started()
signal sync_completed(stats: Dictionary)
# stats keys: documents_upserted, documents_deleted, collections_updated,
#             warnings: Array[String]
signal sync_failed(reason: String)
signal sync_progress(message: String, fraction: float)
```

---

## Threading Model

The importer runs entirely on a `Thread`. All SQLite writes use the same
connection opened on that thread. The main thread never touches the importer's
DB connection. When the importer finishes, it calls
`call_deferred("emit_signal", "sync_completed", stats)` on the Runtime
singleton to post results back to the main thread.

The Runtime's read connection (used by the dialogue engine) is a separate
connection opened on its own thread. WAL mode allows concurrent reads and
writes without blocking.

---

## Configuration

Stored in `ProjectSettings` under `tarinoi/*`:

```
tarinoi/api/path    String   Documents endpoint, ending in /documents
```

The API token is not a project setting: it lives in
`user://tarinoi/.credentials` as `api_key=<value>` and never reaches
`project.godot`. Set it via **Tools > Tarinoi: Set Tarinoi API token…**.

`project_id` is derived automatically from the API path (the segment before
`/documents`). It is not a user-facing setting, and it names the database file.

Programmatic configuration:

```gdscript
TarinoiRuntime.configure()   # reads tarinoi/api/path
TarinoiRuntime.sync()        # triggers the importer on a background thread
```
