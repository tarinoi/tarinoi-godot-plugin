extends GutTest

var _dv: TarinoiDataVersion


func before_each() -> void:
	_dv = TarinoiDataVersion.new()


func test_matching_version_is_compatible() -> void:
	var err := _dv.check(TarinoiDataVersion.SUPPORTED_VERSION)
	assert_eq(err, "", "matching data_version should not be fatal")


func test_null_data_version_is_ignored() -> void:
	var err := _dv.check(null)
	assert_eq(err, "", "null data_version (pre-versioning legacy doc) should not be checked")


func test_empty_data_version_is_ignored() -> void:
	var err := _dv.check("")
	assert_eq(err, "", "empty data_version should not be checked")


func test_patch_mismatch_is_not_fatal() -> void:
	var err := _dv.check("2.0.1")
	assert_eq(err, "", "patch mismatch should not be fatal")


func test_minor_mismatch_is_not_fatal() -> void:
	var err := _dv.check("2.1.0")
	assert_eq(err, "", "minor mismatch should not be fatal")


func test_major_mismatch_is_fatal() -> void:
	var err := _dv.check("1.0.0")
	assert_ne(err, "", "major mismatch must return a non-empty fatal error")
	assert_push_error_count(1, "major mismatch logs via TarinoiLogger.error")


func test_unparseable_version_is_not_fatal() -> void:
	var err := _dv.check("not-a-version")
	assert_eq(err, "", "unparseable version should be logged and skipped, not fatal")


func test_repeated_major_mismatch_still_returns_fatal_each_time() -> void:
	# The message is only logged once per distinct version, but every call
	# must still report the fatal condition so callers keep aborting.
	var first := _dv.check("1.0.0")
	var second := _dv.check("1.0.0")
	assert_ne(first, "")
	assert_ne(second, "")
	assert_eq(first, second)
	assert_push_error_count(1, "the second call for the same version must not log again")
