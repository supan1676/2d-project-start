extends PickableItem
# AmmoCrate.gd — Refills agent ammo on pickup

func _ready() -> void:
	super._ready()
	modulate = Color.CYAN


func apply_effect(agent) -> void:
	if agent.has_method("refill_ammo"):
		agent.refill_ammo()

	# BUG FIX #12: Show "+AMMO" instead of misleading damage number "30"
	var game = get_tree().get_first_node_in_group("game_manager")
	if game:
		_show_pickup_text(game, agent.global_position)


func _show_pickup_text(game, pos: Vector2) -> void:
	var label = Label.new()
	label.text = "+AMMO"
	label.global_position = pos + Vector2(-25, -30)
	label.z_index = 20

	var settings = LabelSettings.new()
	settings.font_size = 36
	settings.font_color = Color.CYAN
	settings.outline_size = 10
	settings.outline_color = Color.BLACK
	label.label_settings = settings
	game.add_child(label)

	var tween = game.create_tween().set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 100.0, 0.6).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.4).set_ease(Tween.EASE_IN).set_delay(0.2)
	tween.chain().tween_callback(label.queue_free)
