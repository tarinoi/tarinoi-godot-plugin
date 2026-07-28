# REST API Sync

## Purpose

Provide an alternative sync source that reads project documents from the
Tarinoi REST API instead of a cloned Git repository. This enables near-real-time
preview of dialogue changes — including uncommitted work-in-progress — removing
the commit/push/pull cycle from the inner development loop.

The Git-based sync remains available. The developer chooses between the two via
a project setting.

---

## Motivation

The Git sync path has inherent latency: a writer must commit and push, and the
developer must pull or re-sync before seeing the change in-game. For iterative
dialogue work this is significant friction. The API sync path reads from the
live Tarinoi server and can include uncommitted buffer layer documents, so
changes appear in-game as soon as they are saved in Tarinoi.

---

## New Project Settings

| Setting | Type | Default | Notes |
|---|---|---|---|
| `tarinoi/sync_source` | `STRING` | `"git"` | `"git"` or `"api"` |
| `tarinoi/api/path` | `STRING` | `""` | Full documents endpoint URL, e.g. `https://tarinoi.app/k/api/v1/<groupId>/<projectId>/documents`. Tarinoi provides a copy-paste link in the project settings. |
| `tarinoi/api/token` | `STRING` (status only) | — | Displays whether a token is saved. The token itself is **not** a project setting: it lives in `user://tarinoi/.credentials` as `api_key=<value>`, alongside the GitLab token, and never reaches `project.godot`. Set it via **Tools > Tarinoi: Set Tarinoi API token…**. |
| `tarinoi/behaviour/committed_only` | `BOOL` | `false` | When true, filters out buffer layer documents at all times, regardless of sync source. Only main-layer documents are visible to the runtime. |

`api_path` must include the `/documents` suffix — the plugin uses it verbatim
as the base URL for paged requests.

---

## API Sync Flow

### Endpoint used

```
GET <api_path>/documents
```

With `Authorization: Bearer <api_key>`. Responses are NDJSON: one JSON object
per line. The final line of a paginated response is `{"cursor": <number>}`.

### Full sync (first run)

1. Fetch `/documents` with no `cursor` parameter, no `layer_id` filter
   (returns all layers).
2. Parse each NDJSON line as a document. Pass it through `_upsert_document`
   (same logic as the Git importer, which handles tombstones and active-flag
   deletions).
3. If a cursor object appears at the end, record it and immediately request the
   next page with `?cursor=<value>`. Repeat until no cursor object.
4. Write the final cursor value to DB metadata as `api_sync_cursor`.
5. Emit `sync_completed`.

### Incremental sync (subsequent runs)

1. Read `api_sync_cursor` from DB metadata.
2. Fetch `/documents?cursor=<value>`.
3. Process all returned documents as above.
4. Update `api_sync_cursor` to the new cursor value.

The cursor is an `update_key` value. It increases monotonically (with possible
gaps for deleted documents). Passing a cursor returns only documents whose
`update_key` is greater than that value, so incremental syncs are fast when
there are few changes.

### Sync trigger

Same triggers as Git sync: the "Tarinoi: Clone / Sync" menu item, and at game
startup via `TarinoiRuntime.sync()` (which checks `sync_source` and calls the
appropriate importer). The Git path is unchanged when `sync_source = "git"`.

---

## Buffer Layer and the Two-Layer DB

### What the API returns

The API returns documents from all layers. Main project documents carry
`layer_id = "tarinoi:main-project-layer"`. Uncommitted work-in-progress
documents carry `layer_id = "tarinoi:main-project-layer.buffer"`.

The `layer_id` column already exists in the local `documents` table.

### Merge semantics

The buffer layer "overwrites" the main layer. For any `(document_id,
collection_id)` pair:

- If a buffer layer document exists and is active: use the buffer version.
- If a buffer layer document exists and is inactive (`is_active: false`, i.e.
  `is_tombstone || is_archived || is_moved`): the document does not exist for
  the dialogue, regardless of what the main layer contains.
- If no buffer layer document exists: use the main layer document (subject to
  the usual activity filter).

### `committed_only` toggle

When `committed_only = true`, the merge logic is bypassed entirely.
All runtime queries add `AND layer_id = 'tarinoi:main-project-layer'` and the
buffer is invisible. This is the same query the Git sync path always produces
(Git never writes buffer layer documents).

### Runtime query changes

Currently every runtime query filters with:
```sql
AND is_tombstone = 0 AND is_archived = 0 AND is_moved = 0
```

In merged mode (API sync, `committed_only = false`) this becomes:

```sql
AND (
  -- buffer layer active: use buffer version
  (layer_id = 'tarinoi:main-project-layer.buffer'
   AND is_tombstone = 0 AND is_archived = 0 AND is_moved = 0)
  OR
  -- main layer active, no buffer override present
  (layer_id = 'tarinoi:main-project-layer'
   AND is_tombstone = 0 AND is_archived = 0 AND is_moved = 0
   AND NOT EXISTS (
     SELECT 1 FROM documents b
     WHERE b.document_id = d.document_id
       AND b.collection_id = d.collection_id
       AND b.layer_id = 'tarinoi:main-project-layer.buffer'
   ))
)
```

This query is correct and fast for typical Tarinoi collection sizes (hundreds
to low thousands of documents). The `NOT EXISTS` subquery is filtered by primary
key `(document_id, collection_id)`.

The filter is identical across all query sites (runtime, codegen, dispatcher).
A helper in `TarinoiDB` should return the appropriate WHERE fragment based on
the active settings, so call sites do not duplicate the logic.

---

## Implementation Notes

### HTTP in Godot

Godot's `HTTPClient` can be driven from a background thread without being a
scene node, consistent with the existing thread-per-sync pattern in the Git
importer. Use `HTTPClient` directly rather than `HTTPRequest` (which requires
a node in the scene tree).

Pagination is sequential by design: fetch a page, parse it, then fetch the
next cursor. No concurrency needed.

### NDJSON parsing

No library needed. Split the response body on `"\n"`, call
`JSON.parse_string()` on each non-empty line, check whether the result is a
`{"cursor": ...}` object or a document.

### TLS and local development

`tarinoi.local` uses a self-signed or locally-issued certificate. Godot's
`HTTPClient` will reject it unless TLS verification is disabled.

Add a boolean project setting `tarinoi/api/skip_tls_verify` (default `false`,
hidden or clearly labelled as dev-only). When true, configure the
`TLSOptions` passed to `HTTPClient.connect_to_host()` to skip verification.
Do not ship with this enabled.

### "Clear local data" and layer isolation

The existing "Tarinoi: Clear local data" menu item deletes the entire DB.
This is correct for both sync sources — a fresh API sync will repopulate the
DB from scratch including both layers.

### Credentials file format (extended)

```
token=glpat-xxxx           # GitLab personal access token
api_key=tarinoi-xxxx       # Tarinoi REST API key
```

Both keys are optional and independent.

---

## Automatic Background Polling

When `sync_source = "api"`, the plugin supports optional background polling in
addition to the manual sync trigger.

### Settings

| Setting | Type | Default | Notes |
|---|---|---|---|
| `tarinoi/api/poll_enabled` | `BOOL` | `false` | Enable automatic polling. |
| `tarinoi/api/poll_interval` | `INT` | `10` | Seconds between polls. |

### Pause on inactivity

> **Not yet implemented.** The current implementation uses a plain `Timer` that
> runs continuously while the game is playing. The activity-aware pause
> described below is a planned enhancement.

Continuous polling while the developer is away wastes API calls. The planned
implementation would monitor editor window focus (via `focus_entered` /
`focus_exited` on the main window) and pause the poll timer when the editor
loses focus, resuming when focus returns.

The poll timer is owned by `TarinoiRuntime` and drives incremental syncs
on the same code path used by the manual trigger.

---

## Write API

Out of scope for this feature. Pushing declarations from GDScript back to
Tarinoi via the write API is specified in
[push-bindings.md](push-bindings.md).
