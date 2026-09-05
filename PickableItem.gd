extends Area2D
class_name PickableItem
# PickableItem.gd — Base class for world pickups

@export var lifetime = 20.0

func _ready() -> void:
	add_to_group("items")

	# BUG FIX #7: Was tweening alpha 1.0→1.0 (no-op). Now: solid → blink → fade
	var tween = create_tween()
	tween.tween_interval(lifetime * 0.6)  # Stay solid for 60%
	# Blink warning for 20%
	for i in range(5):
		tween.tween_property(self, "modulate:a", 0.3, lifetime * 0.02)
		tween.tween_property(self, "modulate:a", 1.0, lifetime * 0.02)
	# Fade out for last 20%
	tween.tween_property(self, "modulate:a", 0.0, lifetime * 0.2)
	tween.tween_callback(queue_free)

	body_entered.connect(_on_body_entered)


func _on_body_entered(body) -> void:
	if body.is_in_group("agents"):
		apply_effect(body)
		queue_free()


func apply_effect(_agent) -> void:
	pass  # Override in subclasses
