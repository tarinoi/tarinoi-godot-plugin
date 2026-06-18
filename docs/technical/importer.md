# Importer

## Responsibility

Clone or update a Tarinoi Git repository and maintain a SQLite mirror of its
documents. Runs on a background thread. Never called at dialogue runtime —
sync is a discrete operation triggered by the game or by an editor action.

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
--   'last_synced_commit'   SHA of last successfully imported commit
--   'project_id'           Tarinoi project ID (set on first import)
--   'repo_url'             Remote URL (set on first import)
```

---

## Git Operations

All git operations use `OS.execute("git", args, output, exit_code)`.
The working directory is the local clone, stored at
`user://tarinoi/repos/<project_id>/`.

### Initial Clone

```
git clone <remote_url> <local_path>
```

After cloning: run a full import (all bucket files).

### Incremental Update

```
git -C <local_path> fetch origin
git -C <local_path> rev-parse FETCH_HEAD              → new_sha
git -C <local_path> diff <last_sha> <new_sha> --name-only  → changed files
git -C <local_path> reset --hard FETCH_HEAD           (update working tree)
```

Filter changed files to those matching `b-\d{3}\.json$`.
Also filter for `collection.json` files (collection manifest changes).

---

## Repository Layout (recap for importer)

```
<repo_root>/
    <document_type_dir>/        e.g. boards/, entities/, functions/, ...
        <collection_id>/
            collection.json     → collection manifest (document_id = collection's own ID)
            manifest.json       → bucket index (internal; not processed by importer)
            b-000.json          → bucket file (object keyed by document_id)
            b-001.json
            ...
            b-019.json          → 20 buckets total per collection
```

Document type directories: `boards`, `entities`, `functions`, `variables`,
`lists`, `templates`, `folders`. The importer processes all of them.

---

## Bucket File Format

Each `b-NNN.json` is a JSON **object keyed by `document_id`**. Example with one document:

```json
{
  "UDVi-1aXnVLtfmoK41J3W": {
    "document_id": "UDVi-1aXnVLtfmoK41J3W",
    "collection_id": "cQtObWxURz3TMluLU4j5z",
    "document_type": "card",
    "layer_id": "tarinoi:main-project-layer",
    "namespace": "document",
    "is_tombstone": false,
    "is_archived": false,
    "is_moved": false,
    "is_active": true,
    "payload": { ... }
  }
}
```

The importer iterates over the object's values and processes each document.

`collection.json` is also a document envelope. Its **`document_id`** is the collection's own ID; `collection_id` on that file refers to the parent collection and is not used when populating the `collections` table.

---

## Upsert Logic

For each document in a changed bucket file:

```
if document.is_tombstone OR document.is_archived OR document.is_moved:
    hard-delete from documents WHERE document_id = ? AND collection_id = ?
else:
    INSERT OR REPLACE INTO documents (...) VALUES (...)
```

Hard-delete on tombstone: the document is gone, no need to retain it.
This keeps the DB clean and the runtime query simple.

For `collection.json` changes: upsert the `collections` table row.

---

## Incremental Sync Cursor

After a successful import:

```sql
UPDATE metadata SET value = '<new_sha>' WHERE key = 'last_synced_commit';
```

On next sync, `<new_sha>` becomes `<last_sha>` in the diff command.

If `last_synced_commit` is absent (first run after clone), do a full import:
walk all `b-NNN.json` files in all collection directories.

---

## Full Import (first run)

Walk `<repo_root>` recursively. For each directory containing a
`collection.json`:
1. Upsert the collection into `collections`.
2. For each `b-NNN.json` in that directory: parse and upsert all documents.

Order does not matter — there are no foreign key constraints in SQLite that
would require a specific insert order.

---

## Error Handling

| Condition | Behaviour |
|---|---|
| `git` not on PATH | Emit `sync_failed("git not found")`, abort |
| Network failure during fetch | Emit `sync_failed("fetch failed: <stderr>")`, abort |
| Malformed JSON in bucket file | Log warning with file path, skip the file, continue |
| SQLite write error | Emit `sync_failed("db error: <message>")`, abort |
| Partial sync (some files fail) | Emit `sync_completed` with `warnings` list |

`last_synced_commit` is only updated after all files are processed without
a fatal error. A fatal error leaves the cursor at the previous commit so the
next sync retries from the same point.

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
tarinoi/repo_url        String   Remote URL (without credentials)
tarinoi/auto_sync       bool     Sync on game start (default: false)
```

`project_id` is derived automatically from the repo URL slug (last path segment,
`.git` stripped). It is not a user-facing setting.

Access token is stored separately via **Tools → Tarinoi: Set Token…** and written
to `user://tarinoi/.credentials` (outside the project directory).

Programmatic configuration:

```gdscript
TarinoiRuntime.configure(repo_url: String)
TarinoiRuntime.sync()   # triggers importer on background thread
```
