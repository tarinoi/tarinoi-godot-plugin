# Changelog

All notable changes to this plugin are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Core functions.** Regenerate Bindings now scaffolds
  `tarinoi_core_functions.gd` — the reference implementation of Tarinoi's
  built-in `Fn.tarinoi.*` set (flags, counters, text, comparisons) with the
  same semantics as in-app playback — into `tarinoi/codegen/impl_path`
  (default `res://bindings/impl/`). It is written once and never overwritten:
  the file is yours to adapt to your own variable storage. Validate Bindings
  reports a scaffold that is out of date or missing a function.
- `TarinoiVariables.COLLECTIONS` in the generated variables file maps each
  collection identifier to its class.
- The quickstart scene binds the generated variable classes and
  `TarinoiCoreFunctions` for any collection `_setup_bindings()` leaves
  unbound, so synced content that only uses core functions plays with no code.

- `tarinoi/api/ca_certificate` — path to a PEM whose CA the sync verifies the
  server against instead of the bundled roots. The way to sync from a local
  development server (Caddy's `tls internal`, mkcert).

### Changed
- Supported data format is now `2.0.0`. Function-declaration arguments moved
  from `sub_type`/`allow_literal` to a `value_selectors` list; the plugin never
  read those fields, so this only lifts the version gate that refused to sync
  `2.0.0` documents.

### Fixed
- Several NPC lines passing their gates at once were presented as a numbered
  menu. An NPC set is not a menu: the author picks the line by condition, so
  only the first passing line (by geo.y) is shown, as in-app playback does. A
  set with any PC line in it is still a choice set; NPC lines mixed into one
  are dropped with a warning rather than offered.
- Jump cards are followed again. A jump's destination is its `data.target`
  card-link — the target card's bare document id, possibly on another board —
  not the `target_collection_id` / `target_card_id` pair the runtime expected
  (a documentation error the app corrected on 2026-08-27). Reaching a jump
  used to stop the dialogue with "Jump card … has missing target".
  `TarinoiDataAccess` gains `locate_card(card_id)`; custom providers should
  implement it.
- Settings left over from the removed Git integration (`tarinoi/git/*`,
  `sync_source`, `auto_sync`) are erased from `project.godot` on load, so
  Project Settings > Tarinoi no longer shows a stray "Git" group.
- The API key dialog's placeholder suggested a `tarinoi-` prefix that keys do
  not have.
- `tarinoi/api/skip_tls_verify` could not connect to a server that picks its
  certificate by host name (Caddy and most reverse proxies): Godot's unsafe TLS
  client sends no SNI, so the server aborted the handshake with
  `TLS handshake error: -30592`. The warning now explains this and points at
  `ca_certificate`, which is the working alternative.
- Generated function stubs now carry their `## effect:` comment. Codegen read
  the payload's `effect` key, which does not exist; the field is `function_effect`.

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
