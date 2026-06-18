class_name VarRef

## A resolved-but-not-evaluated reference to a variable in a BindingRegistry collection.
## Passed to function implementations when a Var.collection.name argument is present.
## The implementation decides whether to read, write, or both.
##
## Usage in a function implementation:
##   func SetFlag(flag_ref: Variant) -> void:
##       flag_ref.set_value(true)
##
##   func CheckAndClear(flag_ref: Variant) -> bool:
##       var v := flag_ref.get_value()
##       flag_ref.set_value(false)
##       return v
##
##   func ReadOnly(score: Variant) -> bool:
##       return VarRef.resolve(score) >= 3   # works whether score is VarRef or plain value

var name: String
var collection: String

var _impl: Object  # variable collection implementation


func _init(impl: Object, col: String, var_name: String) -> void:
	_impl = impl
	collection = col
	name = var_name


func _to_string() -> String:
	return "Var.%s.%s" % [collection, name]


func get_value() -> Variant:
	return _impl.get_variable(name)


func set_value(v: Variant) -> void:
	_impl.set_variable(name, v)


## Unwraps a VarRef to its current value. Passes non-VarRef values through unchanged.
## Use this in function implementations that only need to read the value.
static func resolve(v: Variant) -> Variant:
	if v is VarRef:
		return (v as VarRef).get_value()
	return v
