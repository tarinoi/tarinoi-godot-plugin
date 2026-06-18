## Maps collection names to game-provided implementation objects.
## Use bind_function_collection / bind_variable_collection / bind_entity_collection
## to register your implementations before starting dialogue.
class_name BindingRegistry

var _fn:  Dictionary = {}
var _var: Dictionary = {}
var _ent: Dictionary = {}


func bind_function_collection(collection_name: String, impl: Object) -> void:
	_fn[collection_name] = impl


func bind_variable_collection(collection_name: String, impl: Object) -> void:
	_var[collection_name] = impl


func bind_entity_collection(collection_name: String, impl: Object) -> void:
	_ent[collection_name] = impl


func get_fn_impl(collection_name: String) -> Object:
	return _fn.get(collection_name, null)


func get_var_impl(collection_name: String) -> Object:
	return _var.get(collection_name, null)


func get_ent_impl(collection_name: String) -> Object:
	return _ent.get(collection_name, null)
