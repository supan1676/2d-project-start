extends Area2D
# base.gd — Defense objective with per-frame damage tracking for RL reward

var health = 500
var max_health = 500
var damage_this_frame = false


func _ready() -> void:
	add_to_group("base")


func _physics_process(_delta: float) -> void:
	damage_this_frame = false


func take_damage(amount: int) -> void:
	if health <= 0:
		return

	health = clamp(health - amount, 0, max_health)
	damage_this_frame = true

	modulate = Color.RED
	var tween = create_tween()
	tween.tween_property(self, "modulate", Color.WHITE, 0.1)

	if health <= 0:
		modulate = Color(0.2, 0.2, 0.2)
