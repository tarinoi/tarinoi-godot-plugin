# Tarinoi Godot Plugin — Architecture

## Purpose

A reusable Godot 4 plugin that pulls a Tarinoi project from the Tarinoi REST
API (or a Git remote), maintains a local SQLite mirror of the dialogue database,
and exposes a runtime for driving branching dialogue in-engine. A demo scene
ships with the plugin to validate the Tarinoi data model and demonstrate
integration.

---

## Repository Layout

```
addons/tarinoi/
    plugin.cfg
    plugin.gd                  # EditorPlugin entry point + tool menu items
    autoload/
        TarinoiRuntime.gd      # Singleton: the dialogue server
    core/
        importer.gd            # Git sync + SQLite upsert
        api_importer.gd        # REST API sync (NDJSON, incremental cursor)
        db.gd                  # SQLite connection wrapper + layer-merge filter
        expression_parser.gd   # Parses Fn/Var/Ent/Ls expressions
        binding_registry.gd    # Stores collection→impl mappings
        dispatcher.gd          # Resolves + invokes bound callables
    codegen/
        codegen.gd             # Reads DB, emits GDScript binding stubs
    schema/
        documents.sql          # SQLite CREATE TABLE statements (checked in)
demo/
    demo_3d.tscn / demo_3d.gd  # Main demo scene (3D world + intercom trigger)
    demo.tscn / demo.gd        # Flat 2D demo scene (legacy)
    bindings/
        generated/             # Output of codegen (committed after first run)
            tarinoi_functions.gd
            tarinoi_variables.gd
            tarinoi_lists.gd
            tarinoi_entities.gd
        impl/
            global_functions.gd
            global_variables.gd
tarinoi/
    bundled/
        {project_id}.db        # Snapshot DB for offline/export builds (see below)
```

---

## Component Map

```
┌───────────────────────────────────────────────────────┐
│  Tarinoi REST API  (NDJSON over HTTPS)                │
└──────────────────────┬────────────────────────────────┘
                       │ incremental sync (cursor-based)
┌──────────────────────▼────────────────────────────────┐
│  ApiImporter  (api_importer.gd)                       │
│  · HTTPClient, background Thread                      │
│  · upserts documents and collections into SQLite      │
│  · writes api_sync_cursor to DB metadata              │
└──────────────────────┬────────────────────────────────┘
                       │
      (alternative: Git sync via importer.gd)
                       │
┌──────────────────────▼────────────────────────────────┐
│  SQLite DB  (db.gd + godot-sqlite GDExtension)        │
│  · one file per project at user://tarinoi/{id}.db     │
│  · WAL mode; schema versioned (auto-migrates)         │
│  · two-layer merge: buffer overrides main             │
└──────────────────────┬────────────────────────────────┘
                       │ queries
┌──────────────────────▼────────────────────────────────┐
│  TarinoiRuntime  (autoload singleton)                 │
│  · owns dialogue state machine                        │
│  · in-memory cache: _collections, _entities, _lists  │
│  · evaluates expressions via Dispatcher               │
│  · emits signals to client UI nodes                   │
└──────┬───────────────┬───────────────────────────────-┘
       │ signals        │ calls
┌──────▼──────┐  ┌──────▼──────────────────────────────┐
│  Client UI  │  │  Dispatcher  (dispatcher.gd)         │
│  (scene     │  │  · looks up collection impl in       │
│   nodes)    │  │    BindingRegistry                   │
└─────────────┘  │  · calls method on impl object       │
                 └──────────────────────────────────────┘
                        ▲
                 ┌──────┴──────────────────────────────┐
                 │  BindingRegistry (binding_registry)  │
                 │  · maps collection_name → GDObject   │
                 │  · populated by game code at start   │
                 └─────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Codegen  (codegen.gd)  — editor-only, not at runtime  │
│  · reads functions/variables/lists/entities from DB     │
│  · writes tarinoi_functions.gd etc. into demo/bindings  │
│  · raises errors for missing or mismatched bindings     │
└─────────────────────────────────────────────────────────┘
```

---

## Key Design Constraints

**Threading.** Import (both API and Git) runs on a background `Thread`. Sync
completion is posted back to the main thread via signal. Card queries inside the
dialogue state machine are synchronous (the DB is small enough that latency is
negligible).

**Dialogue is non-blocking.** `TarinoiRuntime` is event-driven. It advances
state when the client calls `advance()` or `select_choice(index)`. It never
polls or spins.

**The plugin is unopinionated about game state.** It has no variable store.
All function calls, variable reads, and variable writes are dispatched to
game-registered implementations. The plugin defines the dispatch protocol,
not the semantics.

**Client/server separation.** `TarinoiRuntime` emits signals. Client UI nodes
connect to those signals. The runtime never references UI nodes directly.
Swapping the UI is a client-only change.

**Two-layer merge.** When `sync_source = "api"` and `committed_only = false`,
the DB stores both a main layer and a buffer layer. The buffer layer
(`.buffer` namespace) overrides or suppresses the main layer in all queries,
enabling live preview of in-progress edits. See `TarinoiDB.active_filter()`.

---

## Offline / Bundled Mode (for exported executables)

Exported games can run without any network access by using a pre-populated
SQLite snapshot bundled into the PCK:

1. **Snapshot tool** (`Tools > Tarinoi: Snapshot for Export`) copies the
   current live DB from `user://tarinoi/{project_id}.db` into
   `res://tarinoi/bundled/{project_id}.db` and scrubs the `api_path` and
   `api_sync_cursor` metadata entries (development artifacts).

2. **At startup**, if offline mode is active, `TarinoiRuntime` copies the
   bundled DB from `res://tarinoi/bundled/` → `user://tarinoi/` before
   opening it. SQLite requires a real filesystem path, so the copy step is
   necessary even in exports (the PCK is read-only).

3. **`sync()`** returns immediately in offline mode, emitting `sync_completed`
   with empty stats so client scenes proceed normally without network calls.

**Activation:**
- Editor testing: set `tarinoi/offline_mode = true` in Project Settings.
- Exported build: add custom feature tag `tarinoi_offline` in the export preset.

**Buffer layer in offline mode:** excluded by definition — the snapshot
contains only committed (main-layer) content, so the two-layer merge logic finds
no buffer documents and behaves identically to `committed_only = true`.

---

## Third-Party Dependencies

| Dependency | Purpose | Source |
|---|---|---|
| godot-sqlite | SQLite GDExtension for Godot 4 | github.com/2shady4u/godot-sqlite |

The godot-sqlite binaries are gitignored and must be present locally in
`addons/godot-sqlite/bin/`. The `.gdextension` file references the correct
library name for each platform (macOS framework, Windows DLL, Linux SO).

---

## Data Flow: API Sync

1. Game calls `TarinoiRuntime.sync()`.
2. `TarinoiApiImporter` runs on background thread:
   a. Reads `api_sync_cursor` from DB metadata (empty on first sync).
   b. Fetches NDJSON pages from the API endpoint (Bearer auth).
   c. Upserts each document / collection into SQLite.
   d. Stores the new cursor; repeats until the server signals completion.
3. On completion: emits `sync_completed(stats)` on main thread; runtime
   refreshes in-memory cache (`_load_global_cache()`).

## Data Flow: Dialogue

1. Game calls `TarinoiRuntime.start_dialogue(collection_id, card_id)`.
2. Runtime loads the start card from SQLite.
3. Runtime evaluates the card's `input_pin.condition` via Dispatcher.
4. If condition passes:
   - NPC entity: emit `line_ready(line_data)` to clients.
   - PC entity: collect candidate next cards, evaluate their conditions,
     emit `choices_ready(choices)`.
5. Client calls `advance()` (NPC) or `select_choice(index)` (PC).
6. Runtime evaluates `output_selector` if present to pick the output pin,
   follows the connection to the next card, repeats from step 3.
7. On terminal node: emit `dialogue_ended()`.

---

## Godot Version

Godot 4.6+. GDScript 2.0. Physics: Jolt. Rendering: Forward Plus.
