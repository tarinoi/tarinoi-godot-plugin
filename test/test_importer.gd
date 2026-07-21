extends GutTest

const TarinoiImporterClass := preload("res://addons/tarinoi/core/importer.gd")

var _importer: RefCounted


func before_each() -> void:
	_importer = TarinoiImporterClass.new()


func _make_db() -> TarinoiDB:
	var db := TarinoiDB.new()
	var ok := db.open("__test_importer__")
	assert_true(ok, "DB opened for test")
	return db


func test_upsert_document_stores_identifier_column() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var doc := {
		"document_id": "doc1", "collection_id": "col1", "layer_id": "tarinoi:main-project-layer",
		"document_type": "entity", "namespace": "document", "identifier": "sylvia_whistler",
		"update_key": 1, "is_tombstone": false, "is_archived": false, "is_moved": false,
		"payload": {},
	}
	_importer._upsert_document(doc, db, stats)
	var rows := db.query_rows("SELECT identifier FROM documents WHERE document_id = ?", ["doc1"])
	assert_eq(rows.size(), 1)
	assert_eq(rows[0]["identifier"], "sylvia_whistler")
	db.close()


func test_upsert_document_major_version_mismatch_sets_fatal_error() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var doc := {
		"document_id": "doc2", "collection_id": "col1", "layer_id": "tarinoi:main-project-layer",
		"document_type": "line", "namespace": "document", "identifier": null,
		"update_key": 1, "is_tombstone": false, "is_archived": false, "is_moved": false,
		"payload": {}, "data_version": "2.0.0",
	}
	_importer._upsert_document(doc, db, stats)
	assert_true(stats.has("fatal_error"), "major data_version mismatch should set fatal_error")
	assert_eq(stats["documents_upserted"], 0, "document must not be upserted on fatal mismatch")
	assert_push_error_count(1, "major mismatch logs via TarinoiLogger.error")
	db.close()


func test_upsert_document_compatible_version_proceeds_normally() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var doc := {
		"document_id": "doc3", "collection_id": "col1", "layer_id": "tarinoi:main-project-layer",
		"document_type": "line", "namespace": "document", "identifier": null,
		"update_key": 1, "is_tombstone": false, "is_archived": false, "is_moved": false,
		"payload": {}, "data_version": TarinoiDataVersion.SUPPORTED_VERSION,
	}
	_importer._upsert_document(doc, db, stats)
	assert_false(stats.has("fatal_error"))
	assert_eq(stats["documents_upserted"], 1)
	db.close()


func test_upsert_collection_major_version_mismatch_sets_fatal_error() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var col_data := {
		"document_id": "col1", "payload": {"label": "Test"}, "data_version": "2.0.0",
	}
	_importer._upsert_collection(col_data, db, stats)
	assert_true(stats.has("fatal_error"))
	assert_eq(stats["collections_updated"], 0)
	assert_push_error_count(1, "major mismatch logs via TarinoiLogger.error")
	db.close()
