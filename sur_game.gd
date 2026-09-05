extends Node2D
# sur_game.gd — Game manager
# Changes: ENV-1 (wave system), ENV-2 (episode length curriculum),
#          ENV-3 (biased ammo spawns), REW-3 (base_destroyed -20),
#          REW-4 (team kill signal), MON-1 (console stats)

const SQUAD_SIZE = 5
const MAX_EPISODE_TIME = 120.0

var defense_base = null
var time_elapsed = 0.0
var episode_count = 0
var best_run_reward = -9999.0
var difficulty_level = 1

# ENV-2: Episode length curriculum
var _episode_length_buffer: Array = []
const EPISODE_BUFFER_SIZE = 20

# ENV-1: Wave system
enum WaveState { IDLE, SPAWNING, FIGHTING, RESTING }
var wave_state: WaveState = WaveState.IDLE
var wave_number: int = 0
var _wave_spawn_timer: float = 0.0
var _wave_spawn_interval: float = 0.0
var _wave_spawned_count: int = 0
var _wave_total_count: int = 0
var _rest_timer: float = 0.0
const REST_DURATION = 8.0
const SPAWN_DURATION = 3.0

# MON-1: Episode stats tracking
var _ep_total_kills: int = 0
var _ep_ammo_pickups: int = 0

@onready var camera = $Camera2D

const DIFFICULTY_CONFIG = {
	1: {"speed": 50.0,  "max_mobs": 10, "base_wave": 5,  "label": "EASY"},
	2: {"speed": 80.0,  "max_mobs": 15, "base_wave": 8,  "label": "NORMAL"},
	3: {"speed": 120.0, "max_mobs": 25, "base_wave": 12, "label": "HARD"},
}

var _stats_labels = {}


func _ready() -> void:
	add_to_group("game_manager")
	randomize()
	_build_hud()
	defense_base = get_tree().get_first_node_in_group("base")
	call_deferred("reset_game")


func _physics_process(delta: float) -> void:
	time_elapsed += delta
	_update_hud()
	_check_curriculum()

	var living = _get_living_agents()

	# Game over: all agents dead
	if living.size() == 0:
		reset_game()
		return

	# REW-3: Base destroyed penalty reduced from -50 to -20
	if is_instance_valid(defense_base) and defense_base.health <= 0:
		for agent in living:
			if agent.has_node("AIController2D"):
				var brain = agent.get_node("AIController2D")
				brain.reward -= 20.0
				brain.current_episode_reward -= 20.0
				brain.done = true
		reset_game()
		return

	# Episode time limit — milestones handled by RL_Controller
	if time_elapsed >= MAX_EPISODE_TIME:
		for agent in living:
			if agent.has_node("AIController2D"):
				agent.get_node("AIController2D").done = true
		reset_game()
		return

	# Base alarm
	if is_instance_valid(defense_base) and defense_base.health > 0 and defense_base.health < 100:
		_play_sfx("alarm")

	# ENV-1: Wave system state machine
	_process_waves(delta)

	# Independent ammo spawn (5% per second, biased toward agents)
	if randf() < 0.05 * delta * 5.0:
		_spawn_biased_ammo()


# === ENV-1: Wave System ===

func _process_waves(delta: float) -> void:
	match wave_state:
		WaveState.IDLE:
			# Start first wave immediately
			_start_wave()

		WaveState.SPAWNING:
			_wave_spawn_timer -= delta
			if _wave_spawn_timer <= 0.0 and _wave_spawned_count < _wave_total_count:
				_spawn_one_wave_mob()
				_wave_spawned_count += 1
				_wave_spawn_timer = _wave_spawn_interval

			if _wave_spawned_count >= _wave_total_count:
				wave_state = WaveState.FIGHTING

		WaveState.FIGHTING:
			# Check if all wave mobs are dead
			if get_tree().get_nodes_in_group("mobs").size() == 0:
				wave_state = WaveState.RESTING
				_rest_timer = REST_DURATION

		WaveState.RESTING:
			_rest_timer -= delta
			if _rest_timer <= 0.0:
				wave_number += 1
				_start_wave()


func _start_wave() -> void:
	var config = _get_config()
	var base_count = config.get("base_wave", 5)
	_wave_total_count = mini(base_count + wave_number * 2, config.max_mobs)
	_wave_spawned_count = 0
	_wave_spawn_interval = SPAWN_DURATION / max(_wave_total_count, 1)
	_wave_spawn_timer = 0.0  # Spawn first mob immediately
	wave_state = WaveState.SPAWNING


func _spawn_one_wave_mob() -> void:
	var mob = preload("res://mob.tscn").instantiate()
	mob.difficulty_tier = difficulty_level
	mob.type = _roll_mob_type()

	if has_node("%PathFollow2D"):
		%PathFollow2D.progress_ratio = randf()
		mob.global_position = %PathFollow2D.global_position
	else:
		mob.global_position = Vector2.ZERO

	mob.add_to_group("mobs")
	add_child(mob)


func _roll_mob_type() -> int:
	var r = randf()
	match difficulty_level:
		1:
			return 1 if r < 0.1 else 0
		2:
			if r < 0.2: return 1
			elif r < 0.3: return 2
			else: return 0
		_:
			if r < 0.3: return 1
			elif r < 0.5: return 2
			else: return 0


# === Episode Reset ===

func reset_game() -> void:
	# ENV-2: Record episode duration
	if episode_count > 0:
		_episode_length_buffer.append(time_elapsed)
		if _episode_length_buffer.size() > EPISODE_BUFFER_SIZE:
			_episode_length_buffer.pop_front()

	# MON-1: Log episode stats
	if episode_count > 0:
		var living = _get_living_agents()
		var base_hp = defense_base.health if is_instance_valid(defense_base) else 0
		var total_reward = 0.0
		var ac = 0
		for a in get_tree().get_nodes_in_group("agents"):
			if is_instance_valid(a) and a.has_node("AIController2D"):
				total_reward += a.get_node("AIController2D").current_episode_reward
				ac += 1
		var avg_r = total_reward / max(ac, 1)
		print("EP %d | %.0fs | wave=%d | alive=%d | base=%d | kills=%d | avg_r=%.1f | diff=%s" % [
			episode_count, time_elapsed, wave_number, living.size(), base_hp,
			_ep_total_kills, avg_r, _get_config().label
		])

	time_elapsed = 0.0
	episode_count += 1
	_ep_total_kills = 0
	_ep_ammo_pickups = 0

	# Reset brains
	for agent in get_tree().get_nodes_in_group("agents"):
		if is_instance_valid(agent) and agent.has_node("AIController2D"):
			var brain = agent.get_node("AIController2D")
			if brain.current_episode_reward > best_run_reward:
				best_run_reward = brain.current_episode_reward
			brain.zero_reward()
			if brain.has_method("reset_rl_state"):
				brain.reset_rl_state()
			else:
				brain.current_episode_reward = 0.0

	# Clean up
	get_tree().call_group("mobs", "queue_free")
	get_tree().call_group("bullets", "queue_free")
	get_tree().call_group("items", "queue_free")

	# Reset base
	if is_instance_valid(defense_base):
		defense_base.health = 500
		defense_base.modulate = Color.WHITE

	# Respawn missing agents
	var agents = get_tree().get_nodes_in_group("agents")
	var missing = SQUAD_SIZE - agents.size()
	var spawn_positions = [
		Vector2(2072, 2167), Vector2(641, 3528),
		Vector2(2843, 832), Vector2(875, 1118), Vector2(501, 1132),
	]
	for i in range(missing):
		var new_agent = load("res://player.tscn").instantiate()
		new_agent.add_to_group("agents")
		var idx = (agents.size() + i) % spawn_positions.size()
		new_agent.position = spawn_positions[idx]
		add_child(new_agent)

	# Assign roles, reset agents
	var all_agents = get_tree().get_nodes_in_group("agents")
	var formation_offsets = [
		Vector2(-150, -100), Vector2(-150, 100),
		Vector2(0, 0),
		Vector2(150, -100), Vector2(150, 100),
	]
	for i in range(all_agents.size()):
		var agent = all_agents[i]
		if not is_instance_valid(agent): continue
		agent.role = 1 if i == 2 else 0
		agent.formation_offset = formation_offsets[i % SQUAD_SIZE]
		if agent.has_method("reset_player"):
			agent.reset_player()
		if agent.has_node("AIController2D"):
			var brain = agent.get_node("AIController2D")
			brain.done = false
			brain._prev_base_health = 500.0

	# ENV-1: Reset wave state
	wave_number = 0
	wave_state = WaveState.IDLE


# === REW-4: Team Kill Reward ===

func notify_team_kill(killer_agent) -> void:
	_ep_total_kills += 1
	for agent in get_tree().get_nodes_in_group("agents"):
		if not is_instance_valid(agent) or agent == killer_agent or agent.get("is_dead"):
			continue
		if agent.has_node("AIController2D"):
			agent.get_node("AIController2D").on_team_kill()


# Called when an ammo crate is picked up
func notify_ammo_pickup() -> void:
	_ep_ammo_pickups += 1


# Called when a tank mob is killed
func _on_tank_killed(pos: Vector2) -> void:
	_spawn_biased_ammo_at(pos)


# === ENV-3: Biased Ammo Spawn ===

func _spawn_biased_ammo() -> void:
	var living = _get_living_agents()
	var pos: Vector2
	if living.size() > 0:
		# Compute centroid of living agents
		var centroid = Vector2.ZERO
		for a in living:
			centroid += a.global_position
		centroid /= living.size()
		# Random offset within 200px radius
		var offset = Vector2(randf_range(-200, 200), randf_range(-200, 200))
		pos = centroid + offset
		# Clamp to map bounds
		pos.x = clamp(pos.x, 400, 3600)
		pos.y = clamp(pos.y, 400, 3600)
	else:
		pos = Vector2(randf_range(800, 3200), randf_range(800, 3200))
	_spawn_supply_drop(pos)


func _spawn_biased_ammo_at(pos: Vector2) -> void:
	_spawn_supply_drop(pos)


func _spawn_supply_drop(pos: Vector2) -> void:
	var crate = Area2D.new()
	crate.set_script(preload("res://AmmoCrate.gd"))
	crate.add_to_group("items")

	var box = ColorRect.new()
	box.size = Vector2(50, 50)
	box.position = Vector2(-25, -25)
	box.color = Color(0.0, 0.5, 0.5, 0.9)
	crate.add_child(box)

	var icon = Label.new()
	icon.text = "AMMO"
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.size = Vector2(50, 50)
	icon.position = Vector2(-25, -15)
	icon.modulate = Color.CYAN
	crate.add_child(icon)

	var col = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = 40.0
	col.shape = shape
	crate.add_child(col)

	crate.global_position = pos + Vector2(0, -1000)
	add_child(crate)

	var tween = create_tween()
	tween.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	tween.tween_property(crate, "global_position:y", pos.y, 1.5)
	tween.tween_callback(func():
		_play_sfx("thud")
		apply_screenshake(5.0, 0.1)
	)


# === VFX ===

func apply_screenshake(strength: float, duration: float) -> void:
	if not is_instance_valid(camera): return
	var tween = create_tween()
	for i in range(int(duration * 20.0)):
		var offset = Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		tween.tween_property(camera, "offset", offset, 1.0 / 20.0)
	tween.tween_property(camera, "offset", Vector2.ZERO, 0.05)


func spawn_damage_number(pos: Vector2, amount: int) -> void:
	var label = Label.new()
	label.text = str(amount)
	label.global_position = pos + Vector2(randf_range(-25, 25), randf_range(-25, 25))
	label.z_index = 20
	var settings = LabelSettings.new()
	settings.font_size = 48
	settings.font_color = Color.GOLD
	settings.outline_size = 12
	settings.outline_color = Color.BLACK
	label.label_settings = settings
	add_child(label)
	var tween = create_tween().set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 120.0, 0.6).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.4).set_ease(Tween.EASE_IN).set_delay(0.2)
	tween.chain().tween_callback(label.queue_free)


func _play_sfx(_type: String) -> void:
	pass


# === HUD ===

func _build_hud() -> void:
	var canvas = CanvasLayer.new()
	add_child(canvas)

	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -340
	panel.offset_top = 20
	panel.offset_right = -20
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_color = Color(0, 1, 1, 0.5)
	style.set_corner_radius_all(4)
	style.content_margin_left = 15
	style.content_margin_right = 15
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)

	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	panel.add_child(grid)

	for sname in ["EPISODE", "SECTOR", "WAVE", "SQUAD", "BASE", "TIME", "REWARD", "BEST"]:
		var name_label = Label.new()
		name_label.text = sname + ":"
		name_label.modulate = Color(0.4, 1.0, 1.0, 0.6)
		grid.add_child(name_label)
		var value_label = Label.new()
		value_label.text = "---"
		if sname in ["REWARD", "BEST"]:
			value_label.modulate = Color.YELLOW
		elif sname in ["BASE", "SQUAD"]:
			value_label.modulate = Color.GREEN
		elif sname == "WAVE":
			value_label.modulate = Color.ORANGE
		else:
			value_label.modulate = Color.CYAN
		grid.add_child(value_label)
		_stats_labels[sname] = value_label


func _update_hud() -> void:
	var config = _get_config()
	var living = _get_living_agents()

	var total_reward = 0.0
	var ac = 0
	for a in living:
		if a.has_node("AIController2D"):
			total_reward += a.get_node("AIController2D").current_episode_reward
			ac += 1
	var current_reward = total_reward / max(ac, 1)

	var base_hp = defense_base.health if is_instance_valid(defense_base) else 0
	var time_remaining = max(MAX_EPISODE_TIME - time_elapsed, 0.0)

	_set_stat("EPISODE", str(episode_count))
	_set_stat("SECTOR", config.label)
	_set_stat("WAVE", str(wave_number + 1))  # ENV-1: show wave number
	_set_stat("SQUAD", "%d / %d" % [living.size(), SQUAD_SIZE])
	_set_stat("BASE", str(base_hp))
	_set_stat("TIME", "%.0fs" % time_remaining)
	_set_stat("REWARD", "%.1f" % current_reward)
	_set_stat("BEST", "%.1f" % best_run_reward)


func _set_stat(key: String, value: String) -> void:
	if _stats_labels.has(key):
		_stats_labels[key].text = value


# === ENV-2: Curriculum by Episode Length ===

func _check_curriculum() -> void:
	if difficulty_level >= 3: return
	if _episode_length_buffer.size() < EPISODE_BUFFER_SIZE: return

	var total = 0.0
	for l in _episode_length_buffer:
		total += l
	var avg = total / _episode_length_buffer.size()

	var promoted = false
	if difficulty_level == 1 and avg > 80.0:
		difficulty_level = 2
		promoted = true
	elif difficulty_level == 2 and avg > 100.0:
		difficulty_level = 3
		promoted = true

	if promoted:
		_episode_length_buffer.clear()
		print("CURRICULUM UP -> %s (Level %d) | avg_ep=%.1fs" % [
			_get_config().label, difficulty_level, avg
		])


func _get_config() -> Dictionary:
	return DIFFICULTY_CONFIG[difficulty_level]


func _get_living_agents() -> Array:
	return get_tree().get_nodes_in_group("agents").filter(
		func(a): return is_instance_valid(a) and not a.get("is_dead")
	)
