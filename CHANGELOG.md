# Changelog

All notable changes to this plugin are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-20

First public release. The API is not stable yet and will change before 1.0.

### Added
- `TarinoiLogger` — log-level-gated logging, controlled by
  `tarinoi/behaviour/log_level`. Everything the plugin prints goes through it,
  so a project that does not want Tarinoi in its Output panel can turn it off.
- `TarinoiDB` — the local SQLite store: connection lifecycle, versioned schema
  creation and migration, metadata, transactions, and query helpers.
- `TarinoiDataVersion` — semantic version compatibility gate for synced
  documents.
- Two-layer (committed/buffer) document merge via `TarinoiDB.active_filter()`,
  so a writer's uncommitted work can be previewed in-game. The
  `tarinoi/behaviour/committed_only` setting restricts the runtime to committed
  content instead.
- `TarinoiDataAccess` — content reads for the runtime, with an overridable seam
  for a custom or off-thread backend, selected by `tarinoi/data_provider`.
- `TarinoiApiImporter` — incremental sync from the Tarinoi documents API:
  NDJSON pages, cursor pagination that resumes after an interruption,
  layer-aware upserts, and failures reported through signals you can act on.
  Runs on a background thread.
- Credentials stored in `user://tarinoi/.credentials`, outside the project
  directory, so an API token cannot be committed or shipped in a build.
- Offline mode: **Tools > Tarinoi: Snapshot for Export** writes the synced
  database into `res://tarinoi/bundled/`, and the runtime seeds from it when
  `tarinoi/behaviour/offline_mode` is set or the `tarinoi_offline` feature tag
  is present. Development metadata is scrubbed from the snapshot.
- Optional background polling while the game runs, so authored changes appear
  without a restart (`tarinoi/api/poll_enabled`, `tarinoi/api/poll_interval`).
- Expression parser for authored conditions and function calls. Malformed
  expressions are reported once and degrade gracefully rather than throwing.
- `BindingRegistry` and `Dispatcher` — registration of the game code behind
  `Fn.*`, `Var.*`, `Ent.*` and `Ls.*`, with short-circuiting boolean logic and
  a parse cache.
- `TarinoiVarRef` — a located-but-unread variable reference, so bound functions
  can write back to authored variables.
- `TarinoiRuntime` autoload — dialogue playback: walks the authored card graph
  and emits signals for the lines and choices to show. The runtime never
  references UI nodes, so the interface is entirely replaceable.
- `TarinoiHistoryStore` — optional seen-card tracking, which drives the
  `visited` flag on choices and the `shown_once` card flag.
- `shown_once` card flag — a card an author marks show-once stops being a valid
  continuation once the player has seen it: dropped from a choice set, or, when
  it is the only way forward, ending the dialogue as an ordinary dead end.
- Binding codegen — generates typed GDScript classes from your synced content,
  run manually or automatically after every sync
  (`tarinoi/codegen/on_sync`), plus a validate-only pass that reports drift
  between your bindings and the authored content without writing files.
- `DialogueTrigger` and `DialogueTrigger2D` nodes for starting dialogue from
  the world, which list the available start cards in the editor when they have
  no target set yet.
- A ready-to-play quickstart scene — an entry-point picker and a scrolling
  dialogue view — and **Tools > Tarinoi: Initialize project**, which drops a
  copy into your project with a place to register your own bindings.
- Tool menu: Initialize project, Sync, Snapshot for Export, Regenerate
  Bindings, Validate Bindings, Set Tarinoi API token…, and Clear local data.
- godot-sqlite is vendored in `addons/godot-sqlite/` for desktop, Android and
  web, so the plugin works on a fresh clone with no separate install.
