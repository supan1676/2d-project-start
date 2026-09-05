extends CharacterBody2D
# SmartSoldier.gd — RL-driven soldier agent
# Changes: OBS-1 (dual-ring raycasts), OBS-2 (reload progress), ENV-4 (death collision)

const SPEED = 400.0
const ACCELERATION = 2000.0
const FRICTION = 1500.0
const MAX_AMMO = 30
const RELOAD_TIME = 4.5
const DAMAGE_RATE = 10.0

var health = 100.0
var ammo: int = MAX_AMMO
var is_reloading = false
var is_dead = false
var is_shooting = false
var is_hitting_wall = false
var safe_to_shoot = false

# RL reward flags (read and cleared by RL_Controller each step)
var just_got_kill = false
var just_took_damage = false
var just_saved_ally = false
var just_refilled = false
var just_got_hit_marker = false
var just_got_intercept_kill = false  # REW-3
var _last_kill_position = Vector2.ZERO  # REW-3: zone kill tracking

# AI inputs (set by RL_Controller.set_action)
var ai_input = Vector2.ZERO
var ai_aim = Vector2.ZERO
var ai_should_shoot = false

enum Role { SOLDIER, MEDIC }
@export var role: Role = Role.SOLDIER

var formation_offset = Vector2.ZERO
var initial_position = Vector2.ZERO

var blackboard: Blackboard = null
var _scanning_time = 0.0
var _idle_timer = 0.0
var _status_label: Label = null
var _reload_generation = 0
var _reload_elapsed = 0.0

# OBS-1: Programmatically created raycasts
var _long_rays: Array[RayCast2D] = []
var _short_rays: Array[RayCast2D] = []

@onready var gun = $gun
@onready var nav_agent = $NavigationAgent2D

enum LOD { FULL, SIMPLE, STATISTICAL }
var _current_lod = LOD.FULL


func _ready() -> void:
	add_to_group("agents")
	initial_position = global_position

	blackboard = Blackboard.new()
	blackboard.update_cognitive("aggressiveness", randf_range(0.2, 0.9))

	var dialogue = SquadDialogue.new()
	add_child(dialogue)

	if role == Role.MEDIC:
		modulate = Color(0.0, 0.8, 1.0)

	_status_label = Label.new()
	_status_label.text = "RELOADING..."
	_status_label.modulate = Color.GREEN
	_status_label.position = Vector2(-40, -160)
	_status_label.z_index = 10
	_status_label.visible = false
	add_child(_status_label)

	# OBS-1: Create dual-ring raycast sensors programmatically
	_create_raycasts()

	await get_tree().create_timer(2.0).timeout
	safe_to_shoot = true


# OBS-1: Create 16 long-range + 16 short-range raycasts (22.5° apart)
func _create_raycasts() -> void:
	var sensor_parent = get_node_or_null("Sensors")
	if not sensor_parent:
		sensor_parent = Node2D.new()
		sensor_parent.name = "Sensors"
		add_child(sensor_parent)

	# Remove existing scene raycasts (we'll recreate all programmatically)
	for child in sensor_parent.get_children():
		if child is RayCast2D:
			child.queue_free()

	for i in range(16):
		var angle = deg_to_rad(i * 22.5)
		# Long-range ray (500px)
		var lr = RayCast2D.new()
		lr.target_position = Vector2(500, 0).rotated(angle)
		lr.enabled = true
		lr.collide_with_areas = false
		lr.collide_with_bodies = true
		sensor_parent.add_child(lr)
		_long_rays.append(lr)

		# Short-range ray (150px)
		var sr = RayCast2D.new()
		sr.target_position = Vector2(150, 0).rotated(angle)
		sr.enabled = true
		sr.collide_with_areas = false
		sr.collide_with_bodies = true
		sensor_parent.add_child(sr)
		_short_rays.append(sr)


func _physics_process(delta: float) -> void:
	if is_dead or health <= 0:
		if not is_dead:
			die()
		return

	# Reset per-frame flags (just_took_damage cleared by RL_Controller)
	is_shooting = false

	# Movement
	_idle_timer += delta
	if ai_input.length() < 0.1:
		ai_input = Vector2.ZERO
		ai_input += Vector2(cos(_idle_timer * 1.5), sin(_idle_timer * 1.2)) * 0.05

	var move_input = ai_input

	# Navigation assist
	if is_instance_valid(blackboard) and blackboard.volatile.is_on_navigation_path:
		nav_agent.target_position = blackboard.volatile.get("nearest_target_pos", global_position)
		if not nav_agent.is_navigation_finished():
			var dir = (nav_agent.get_next_path_position() - global_position).normalized()
			move_input = move_input.lerp(dir, 0.5)

	# Formation steering
	if formation_offset != Vector2.ZERO:
		var target = _get_squad_center() + formation_offset
		if global_position.distance_to(target) > 100.0:
			move_input = move_input.lerp((target - global_position).normalized(), 0.3)

	# Untrained fallback
	if ai_input.length() < 0.1 and is_instance_valid(blackboard) and blackboard.volatile.is_on_navigation_path:
		if not nav_agent.is_navigation_finished():
			move_input = (nav_agent.get_next_path_position() - global_position).normalized() * 0.5

	if _current_lod < LOD.STATISTICAL:
		if move_input != Vector2.ZERO:
			velocity = velocity.move_toward(move_input * SPEED, ACCELERATION * delta)
		else:
			velocity = velocity.move_toward(Vector2.ZERO, FRICTION * delta)

	is_hitting_wall = move_and_slide() and get_slide_collision_count() > 0

	# Aiming
	if ai_aim.length() > 0.1:
		gun.rotation = lerp_angle(gun.rotation, ai_aim.angle(), 15.0 * delta)
		_scanning_time = 0.0
	else:
		_scanning_time += delta
		var sweep = sin(_scanning_time * 2.0) * 0.5
		var base_angle = velocity.angle() if velocity.length() > 10 else gun.rotation
		gun.rotation = lerp_angle(gun.rotation, base_angle + sweep, 2.0 * delta)

	# Shooting
	if ai_should_shoot and safe_to_shoot and not is_reloading:
		gun.shoot(self)
		is_shooting = true

	# Animation
	if _current_lod == LOD.FULL:
		_update_animations()

	_handle_damage(delta)
	_update_lod()

	# Auto-reload
	if ammo <= 0 and not is_reloading:
		_start_reload()

	# OBS-2: Track reload progress
	if is_reloading:
		_reload_elapsed += delta

	_sync_blackboard()


func _update_animations() -> void:
	var sprite = get_node_or_null("%HappyBoo")
	if not sprite: return
	if is_shooting: sprite.play("shoot")
	elif is_reloading: sprite.play("reload")
	elif velocity.length() > 50.0: sprite.play("walk")
	else: sprite.play("idle")


func _update_lod() -> void:
	var game = get_tree().get_first_node_in_group("game_manager")
	if not game or not is_instance_valid(game.camera): return
	var dist = global_position.distance_to(game.camera.global_position)
	if dist > 2000: _current_lod = LOD.STATISTICAL
	elif dist > 800: _current_lod = LOD.SIMPLE
	else: _current_lod = LOD.FULL


func _sync_blackboard() -> void:
	if blackboard == null: return

	blackboard.update_state("health", health)
	blackboard.update_state("ammo", ammo)
	# OBS-2: reload_progress is updated by RL_Controller._update_reload()

	blackboard.update_volatile("velocity", velocity)
	blackboard.update_volatile("linear_speed", velocity.length())
	blackboard.update_volatile("facing_dir", Vector2.RIGHT.rotated(gun.rotation))
	blackboard.update_volatile("is_shooting", is_shooting)
	blackboard.update_volatile("is_hitting_wall", is_hitting_wall)

	# Navigation target
	var game = get_tree().get_first_node_in_group("game_manager")
	var target_pos = global_position
	var base_alive = is_instance_valid(game) and is_instance_valid(game.defense_base) and game.defense_base.health > 0
	var nearest_mob = _find_nearest_mob()

	if base_alive:
		target_pos = game.defense_base.global_position
		if nearest_mob and global_position.distance_to(nearest_mob.global_position) < 800.0:
			target_pos = nearest_mob.global_position
	else:
		if nearest_mob:
			target_pos = nearest_mob.global_position
		else:
			target_pos = _get_squad_center()

	blackboard.update_volatile("is_on_navigation_path", global_position.distance_to(target_pos) > 200.0)
	blackboard.update_volatile("nearest_target_pos", target_pos)


func _handle_damage(delta: float) -> void:
	var overlapping = %hurtbox.get_overlapping_bodies().filter(
		func(b): return b.is_in_group("mobs")
	)
	if overlapping.size() > 0:
		health -= DAMAGE_RATE * overlapping.size() * delta
		just_took_damage = true
		if has_node("%ProgressBar"):
			%ProgressBar.value = health
		if health <= 0.0:
			die()


func _start_reload() -> void:
	is_reloading = true
	_reload_generation += 1
	_reload_elapsed = 0.0
	# OBS-2: Tell the gun to start tracking reload time
	if is_instance_valid(gun):
		gun.start_reload_tracking()
	var my_gen = _reload_generation
	if is_instance_valid(_status_label):
		_status_label.text = "RELOADING..."
		_status_label.visible = true

	await get_tree().create_timer(RELOAD_TIME).timeout

	if my_gen != _reload_generation: return

	ammo = MAX_AMMO
	is_reloading = false
	if is_instance_valid(_status_label):
		_status_label.visible = false


func _get_squad_center() -> Vector2:
	var living = get_tree().get_nodes_in_group("agents").filter(
		func(a): return is_instance_valid(a) and not a.get("is_dead")
	)
	if living.size() == 0: return global_position
	var total = Vector2.ZERO
	for a in living: total += a.global_position
	return total / living.size()


func _find_nearest_mob():
	var nearest = null
	var min_dist = 99999.0
	for mob in get_tree().get_nodes_in_group("mobs"):
		if is_instance_valid(mob):
			var d = global_position.distance_to(mob.global_position)
			if d < min_dist:
				min_dist = d
				nearest = mob
	return nearest


# === Public API ===

func take_heal(amount: float) -> void:
	health = clamp(health + amount, 0.0, 100.0)
	if has_node("%ProgressBar"): %ProgressBar.value = health
	modulate = Color(0.5, 1.0, 0.5)
	create_tween().tween_property(self, "modulate", Color.WHITE, 0.2)


func kill_confirmed() -> void:
	just_got_kill = true


func hit_confirmed() -> void:
	just_got_hit_marker = true


func hero_save_confirmed() -> void:
	just_saved_ally = true


# REW-3: Called when killed zombie was targeting the base
func intercept_kill_confirmed() -> void:
	just_got_intercept_kill = true


# REW-3: Record kill position for zone bonus
func record_kill_position(pos: Vector2) -> void:
	_last_kill_position = pos


func refill_ammo() -> void:
	ammo = MAX_AMMO
	is_reloading = false
	_reload_elapsed = 0.0
	just_refilled = true
	if is_instance_valid(gun):
		gun.reload_time_remaining = 0.0
	if is_instance_valid(_status_label):
		_status_label.visible = false


# ENV-4: Immediate collision removal on death
func die() -> void:
	if is_dead: return
	is_dead = true

	# ENV-4: Remove collision immediately so zombies pathfind past
	set_collision_layer_value(1, false)
	set_collision_mask_value(1, false)
	set_collision_layer_value(2, false)

	var explosion = preload("res://smoke_explosion/smoke_explosion.tscn").instantiate()
	explosion.global_position = global_position
	get_parent().add_child(explosion)

	# ENV-4: Hide after short delay for visual death
	visible = false
	process_mode = PROCESS_MODE_DISABLED

	if has_node("AIController2D"):
		get_node("AIController2D").done = true


func reset_player() -> void:
	is_dead = false
	visible = true
	process_mode = PROCESS_MODE_INHERIT
	set_collision_layer_value(1, true)
	set_collision_mask_value(1, true)
	set_collision_layer_value(2, true)

	global_position = initial_position
	velocity = Vector2.ZERO

	health = 100.0
	ammo = MAX_AMMO
	is_reloading = false
	is_shooting = false
	is_hitting_wall = false
	just_got_kill = false
	just_took_damage = false
	just_saved_ally = false
	just_refilled = false
	just_got_hit_marker = false
	just_got_intercept_kill = false
	_last_kill_position = Vector2.ZERO
	ai_input = Vector2.ZERO
	ai_aim = Vector2.ZERO

	_reload_generation += 1
	_reload_elapsed = 0.0
	if is_instance_valid(gun):
		gun.reload_time_remaining = 0.0

	safe_to_shoot = false
	_restart_spawn_protection()

	if is_instance_valid(_status_label): _status_label.visible = false
	if has_node("%ProgressBar"): %ProgressBar.value = 100.0


func _restart_spawn_protection() -> void:
	await get_tree().create_timer(2.0).timeout
	if not is_dead:
		safe_to_shoot = true
