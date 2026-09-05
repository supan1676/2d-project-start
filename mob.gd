extends CharacterBody2D
# mob.gd — Zombie enemy with type variants, aggro logic, and curriculum scaling

enum Type { NORMAL, RUNNER, TANK }
@export var type: Type = Type.NORMAL

var health = 3
var damage = 10
var speed = 80.0
var difficulty_tier = 1
var attack_cooldown = 0.0
var current_target = null
var base_color = Color.WHITE
var is_dead = false  # BUG FIX #3: Guards against double-kill from multi-bullet hits

var _base_ref = null


func _ready() -> void:
	add_to_group("mobs")
	z_index = 2
	_base_ref = get_tree().get_first_node_in_group("base")
	_apply_type(type)
	if has_node("%Slime"):
		%Slime.play_walk()


func _apply_type(t: Type) -> void:
	type = t
	match type:
		Type.NORMAL:
			health = 3 * difficulty_tier
			speed = 80.0 + difficulty_tier * 10.0
			damage = 10
			modulate = Color.WHITE
			scale = Vector2(1, 1)
		Type.RUNNER:
			health = 1 * difficulty_tier
			speed = 160.0 + difficulty_tier * 20.0
			damage = 5
			modulate = Color.GREEN_YELLOW
			scale = Vector2(0.8, 0.8)
		Type.TANK:
			health = 10 * difficulty_tier
			speed = 40.0 + difficulty_tier * 5.0
			damage = 25
			modulate = Color.ORANGE_RED
			scale = Vector2(1.8, 1.8)
	base_color = modulate


func _physics_process(delta: float) -> void:
	current_target = null

	# Target selection: base first, then nearest agent
	if is_instance_valid(_base_ref) and _base_ref.health > 0:
		current_target = _base_ref

	var living = get_tree().get_nodes_in_group("agents").filter(
		func(a): return is_instance_valid(a) and not a.get("is_dead")
	)

	if living.size() > 0:
		var aggro_range = 800.0 if current_target != null else 99999.0
		var closest = null
		var min_dist = 99999.0

		for agent in living:
			var d = global_position.distance_to(agent.global_position)
			if d < min_dist:
				min_dist = d
				closest = agent

		if min_dist < aggro_range:
			current_target = closest

	# Movement and attack
	if not is_instance_valid(current_target):
		velocity = Vector2.ZERO
		return

	# Don't attack a dead base
	if current_target.is_in_group("base") and current_target.health <= 0:
		current_target = null
		velocity = Vector2.ZERO
		return

	velocity = global_position.direction_to(current_target.global_position) * speed
	move_and_slide()

	attack_cooldown -= delta
	var dist = global_position.distance_to(current_target.global_position)
	var in_range = dist < 40.0 or (current_target.is_in_group("base") and current_target.health > 0 and dist < 350.0)

	if in_range and attack_cooldown <= 0 and current_target.has_method("take_damage"):
		current_target.take_damage(damage)
		attack_cooldown = 1.0
		_flash(Color.RED)


func take_damage(amount: int) -> void:
	# BUG FIX #3: Prevent double-kill when multiple bullets hit the same frame
	if is_dead:
		return

	health -= amount

	var game = get_tree().get_first_node_in_group("game_manager")
	if game:
		game.spawn_damage_number(global_position, amount)

	if health <= 0:
		is_dead = true  # Lock out further damage processing
		if type == Type.TANK and game and game.has_method("_on_tank_killed"):
			game._on_tank_killed(global_position)
		if game:
			game.apply_screenshake(15.0, 0.2)

		var explosion = preload("res://smoke_explosion/smoke_explosion.tscn").instantiate()
		explosion.global_position = global_position
		get_parent().add_child(explosion)

		if has_node("%Slime"):
			%Slime.play_hurt()
		queue_free()
	else:
		# BUG FIX #5: Only flash if mob survives (prevents tween on freed node)
		_flash(Color(10, 10, 10))


func _flash(color: Color) -> void:
	modulate = color
	var tween = create_tween()
	tween.tween_property(self, "modulate", base_color, 0.1)
