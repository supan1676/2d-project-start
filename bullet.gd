extends Area2D
# bullet.gd — Projectile with kill credit and hero-save detection

const SPEED = 1000.0
const RANGE = 1200.0
const IMPACT = preload("res://pistol/impact/impact.tscn")

var shooter_agent = null
var _travelled = 0.0


func _ready() -> void:
	add_to_group("bullets")


func _physics_process(delta: float) -> void:
	var dir = Vector2.RIGHT.rotated(rotation)
	position += dir * SPEED * delta
	_travelled += SPEED * delta
	if _travelled > RANGE:
		queue_free()


func _on_body_entered(body) -> void:
	# Impact VFX
	var impact = IMPACT.instantiate()
	get_parent().add_child(impact)
	impact.global_position = global_position
	impact.global_rotation = global_rotation

	# Medic healing (bullets heal allies instead of hurting them)
	if body.is_in_group("agents"):
		if is_instance_valid(shooter_agent) and shooter_agent.get("role") == 1:
			# BUG FIX #6: Don't heal dead agents
			if body != shooter_agent and not body.get("is_dead") and body.has_method("take_heal"):
				body.take_heal(10.0)
				queue_free()
		return  # Soldier bullets pass through allies

	# Damage mobs
	if body.is_in_group("mobs") and body.has_method("take_damage"):
		body.take_damage(1)

		if is_instance_valid(shooter_agent):
			# Accuracy reward: credit the agent for every bullet that connects
			if shooter_agent.has_method("hit_confirmed"):
				shooter_agent.hit_confirmed()
			_check_hero_save(body)
			if body.health <= 0:
				if shooter_agent.has_method("kill_confirmed"):
					shooter_agent.kill_confirmed()
				# REW-3: Record kill position for zone bonus
				if shooter_agent.has_method("record_kill_position"):
					shooter_agent.record_kill_position(body.global_position)
				# REW-3: Intercept kill (zombie was targeting the base)
				if "current_target" in body and is_instance_valid(body.current_target):
					if body.current_target.is_in_group("base"):
						var base = body.current_target
						if body.global_position.distance_to(base.global_position) < 600.0:
							if shooter_agent.has_method("intercept_kill_confirmed"):
								shooter_agent.intercept_kill_confirmed()
				# REW-4: Team kill signal — notify all other agents
				var game = get_tree().get_first_node_in_group("game_manager")
				if game and game.has_method("notify_team_kill"):
					game.notify_team_kill(shooter_agent)

	queue_free()


func _check_hero_save(mob) -> void:
	if mob.health > 0:
		return
	if not ("current_target" in mob) or not is_instance_valid(mob.current_target):
		return

	var target = mob.current_target
	if target.is_in_group("agents") and target != shooter_agent:
		if shooter_agent.has_method("hero_save_confirmed"):
			shooter_agent.hero_save_confirmed()
