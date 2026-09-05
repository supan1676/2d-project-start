extends AIController2D
# RL_Controller.gd — PPO brain for SmartSoldier
#
# === Observation Vector: 88 floats ===
# [0-31]   16 long-range rays × (dist, type) — 500px, 22.5° apart
# [32-63]  16 short-range rays × (dist, type) — 150px, 22.5° apart
# [64]     health (0-1)
# [65]     ammo ratio (0-1)
# [66]     reload_progress (OBS-2: 1.0=just started → 0.0=done)
# [67-68]  velocity x,y (normalized)
# [69-70]  facing direction x,y
# [71-72]  base direction x,y
# [73]     base distance (0-1)
# [74]     base health (0-1)
# [75-76]  enemy direction x,y
# [77]     enemy distance (0-1)
# [78]     zombie count (normalized)
# [79-80]  item direction x,y
# [81]     item distance (0-1)
# [82]     aggressiveness (OBS-4: kept, panic removed)
# [83]     nearest ally distance (OBS-3)
# [84-85]  nearest ally direction x,y (OBS-3)
# [86]     allies alive normalized (OBS-3)
# [87]     nearest ally health (OBS-3)
#
# Actions: 5 continuous (move_x, move_y, aim_x, aim_y, shoot)

@onready var player = get_parent()
@onready var sensors = player.get_node("Sensors")

var current_episode_reward = 0.0
var _prev_base_health = 500.0

const SPATIAL_RANGE = 2000.0
const ALLY_RANGE = 1000.0
const LONG_RANGE = 500.0
const SHORT_RANGE = 150.0
const NUM_RAYS = 16  # OBS-1: was 8

# REW-1: aim-hit tracking
var _last_shot_hit = false

# REW-2: survival milestones
var _milestones_awarded = [false, false, false, false]
const MILESTONE_TIMES = [30.0, 60.0, 90.0, 120.0]
const MILESTONE_REWARDS = [1.5, 2.5, 4.0, 6.0]

# REW-4: team kill pending reward
var _pending_team_reward = 0.0


# === Observations (88 floats) ===

func get_obs() -> Dictionary:
	var bb: Blackboard = player.blackboard
	if bb == null:
		return {"obs": []}

	_update_long_rays(bb)
	_update_short_rays(bb)
	_update_threat(bb)
	_update_items(bb)
	_update_base(bb)
	_update_zombie_count(bb)
	_update_allies(bb)
	_update_reload(bb)

	return {"obs": bb.get_normalized_observations()}


# OBS-1: Read long-range raycasts (500px, 16 rays)
func _update_long_rays(bb: Blackboard) -> void:
	var data = []
	if player._long_rays.size() > 0:
		for ray in player._long_rays:
			if ray.is_colliding():
				var dist = player.global_position.distance_to(ray.get_collision_point())
				if dist > LONG_RANGE:
					data.append([1.0, 0.0])
				else:
					var collider = ray.get_collider()
					var tid = 0.25
					if is_instance_valid(collider):
						if collider.is_in_group("mobs"): tid = 1.0
						elif collider.is_in_group("obstacles") or collider.is_in_group("base"): tid = 0.5
					data.append([clamp(dist / LONG_RANGE, 0.0, 1.0), tid])
			else:
				data.append([1.0, 0.0])
	while data.size() < NUM_RAYS:
		data.append([1.0, 0.0])
	bb.update_volatile("long_rays", data)


# OBS-1: Read short-range raycasts (150px, 16 rays)
func _update_short_rays(bb: Blackboard) -> void:
	var data = []
	if player._short_rays.size() > 0:
		for ray in player._short_rays:
			if ray.is_colliding():
				var dist = player.global_position.distance_to(ray.get_collision_point())
				if dist > SHORT_RANGE:
					data.append([1.0, 0.0])
				else:
					var collider = ray.get_collider()
					var tid = 0.25
					if is_instance_valid(collider):
						if collider.is_in_group("mobs"): tid = 1.0
						elif collider.is_in_group("obstacles") or collider.is_in_group("base"): tid = 0.5
					data.append([clamp(dist / SHORT_RANGE, 0.0, 1.0), tid])
			else:
				data.append([1.0, 0.0])
	while data.size() < NUM_RAYS:
		data.append([1.0, 0.0])
	bb.update_volatile("short_rays", data)


func _update_threat(bb: Blackboard) -> void:
	var mob = _find_nearest_in_group("mobs")
	if mob:
		var dir = (mob.global_position - player.global_position).normalized()
		var dist = player.global_position.distance_to(mob.global_position)
		bb.update_volatile("nearest_enemy_dir", dir)
		bb.update_volatile("nearest_enemy_dist", clamp(dist / SPATIAL_RANGE, 0.0, 1.0))
	else:
		bb.update_volatile("nearest_enemy_dir", Vector2.ZERO)
		bb.update_volatile("nearest_enemy_dist", 1.0)


func _update_items(bb: Blackboard) -> void:
	var item = _find_nearest_in_group("items")
	if item:
		var dir = (item.global_position - player.global_position).normalized()
		var dist = player.global_position.distance_to(item.global_position)
		bb.update_volatile("nearest_item_dir", dir)
		bb.update_volatile("nearest_item_dist", clamp(dist / SPATIAL_RANGE, 0.0, 1.0))
	else:
		bb.update_volatile("nearest_item_dir", Vector2.ZERO)
		bb.update_volatile("nearest_item_dist", 1.0)


func _update_base(bb: Blackboard) -> void:
	var base = get_tree().get_first_node_in_group("base")
	if is_instance_valid(base):
		var dir = (base.global_position - player.global_position).normalized()
		var dist = player.global_position.distance_to(base.global_position)
		bb.update_volatile("base_dir", dir)
		bb.update_volatile("base_dist", clamp(dist / SPATIAL_RANGE, 0.0, 1.0))
		bb.update_volatile("base_health_norm", clamp(base.health / 500.0, 0.0, 1.0))
	else:
		bb.update_volatile("base_dir", Vector2.ZERO)
		bb.update_volatile("base_dist", 1.0)
		bb.update_volatile("base_health_norm", 0.0)


# OBS-2: Reload progress from gun
func _update_reload(bb: Blackboard) -> void:
	var progress = 0.0
	if player.is_reloading and is_instance_valid(player.gun):
		var dur = player.gun.reload_duration
		if dur > 0:
			progress = clamp(player.gun.reload_time_remaining / dur, 0.0, 1.0)
	bb.update_state("reload_progress", progress)


# OBS-3: Ally awareness
func _update_allies(bb: Blackboard) -> void:
	var nearest = null
	var min_dist = 99999.0
	var alive = 0
	for agent in get_tree().get_nodes_in_group("agents"):
		if not is_instance_valid(agent) or agent == player or agent.get("is_dead"):
			continue
		alive += 1
		var d = player.global_position.distance_to(agent.global_position)
		if d < min_dist:
			min_dist = d
			nearest = agent
	if nearest:
		bb.update_volatile("nearest_ally_dir", (nearest.global_position - player.global_position).normalized())
		bb.update_volatile("nearest_ally_dist", clamp(min_dist / ALLY_RANGE, 0.0, 1.0))
		bb.update_volatile("nearest_ally_health", clamp(nearest.health / 100.0, 0.0, 1.0))
	else:
		bb.update_volatile("nearest_ally_dir", Vector2.ZERO)
		bb.update_volatile("nearest_ally_dist", 1.0)
		bb.update_volatile("nearest_ally_health", 0.0)
	bb.update_volatile("allies_alive_norm", clamp(float(alive) / 4.0, 0.0, 1.0))


func _update_zombie_count(bb: Blackboard) -> void:
	var count = get_tree().get_nodes_in_group("mobs").size()
	var game = get_tree().get_first_node_in_group("game_manager")
	var max_mobs = 25.0
	if game and game.get("DIFFICULTY_CONFIG"):
		var config = game.DIFFICULTY_CONFIG.get(game.difficulty_level, {})
		max_mobs = float(config.get("max_mobs", 25))
	bb.update_volatile("zombie_count_norm", clamp(float(count) / max_mobs, 0.0, 1.0))


# === Reward ===

func get_reward() -> float:
	if player == null or player.get("is_dead"):
		return 0.0

	# REW-1: read and reset hit flag
	var shot_hit_this_frame = _last_shot_hit
	_last_shot_hit = false
	reward = 0.0

	# Survival tick
	reward += 0.01

	# Kill zombie
	if player.just_got_kill:
		reward += 5.0
		# REW-3: zone kill bonus (killed near base)
		var base = get_tree().get_first_node_in_group("base")
		if is_instance_valid(base) and player._last_kill_position != Vector2.ZERO:
			if player._last_kill_position.distance_to(base.global_position) < 300.0:
				reward += 1.5
		player._last_kill_position = Vector2.ZERO
		player.just_got_kill = false

	# REW-3: intercept bonus (killed zombie that was targeting base)
	if player.just_got_intercept_kill:
		reward += 1.0
		player.just_got_intercept_kill = false

	# Hero save
	if player.just_saved_ally:
		reward += 3.0
		player.just_saved_ally = false

	# REW-5: Curriculum-adaptive shoot cost
	if player.is_shooting:
		var game = get_tree().get_first_node_in_group("game_manager")
		var tier = 1
		if game: tier = game.difficulty_level
		match tier:
			1: pass            # EASY: no cost
			2: reward -= 0.02  # NORMAL
			_: reward -= 0.05  # HARD

	# Wall collision
	if player.is_hitting_wall:
		reward -= 0.02

	# Base proximity + base damage
	var base = get_tree().get_first_node_in_group("base")
	if is_instance_valid(base):
		if player.global_position.distance_to(base.global_position) < 600.0:
			reward += 0.005
		if base.health < _prev_base_health:
			var lc = get_tree().get_nodes_in_group("agents").filter(
				func(a): return is_instance_valid(a) and not a.get("is_dead")
			).size()
			reward -= 1.0 / max(lc, 1)
		_prev_base_health = base.health

	# Accuracy hit
	if player.just_got_hit_marker:
		reward += 1.0
		_last_shot_hit = true  # REW-1: flag for aim-hit check
		player.just_got_hit_marker = false

	# REW-1: Aim-hit reward (replaces standalone aim_precision)
	# Only reward aiming when the shot actually connected
	var mob = _find_nearest_in_group("mobs")
	if mob and shot_hit_this_frame:
		var dir = (mob.global_position - player.global_position).normalized()
		var gun_dir = Vector2.RIGHT.rotated(player.gun.rotation)
		if gun_dir.dot(dir) > 0.95:
			reward += 0.04

	# Ammo refill
	if player.just_refilled:
		reward += 2.0
		player.just_refilled = false

	# Damage taken
	if player.just_took_damage:
		reward -= 0.5
		player.just_took_damage = false

	# Death
	if player.health <= 0:
		reward -= 5.0

	# REW-3: Base destroyed penalty (reduced from -50 to -20)
	# (Applied in sur_game.gd on all agents)

	# REW-4: Team kill reward (accumulated from signal)
	if _pending_team_reward > 0:
		reward += _pending_team_reward
		_pending_team_reward = 0.0

	# REW-2: Incremental survival milestones
	var game = get_tree().get_first_node_in_group("game_manager")
	if game:
		var elapsed = game.time_elapsed
		for i in range(MILESTONE_TIMES.size()):
			if not _milestones_awarded[i] and elapsed >= MILESTONE_TIMES[i]:
				reward += MILESTONE_REWARDS[i]
				_milestones_awarded[i] = true

	current_episode_reward += reward
	return reward


# === Actions ===

func get_action_space() -> Dictionary:
	return {"move": {"size": 5, "action_type": "continuous"}}


func set_action(action) -> void:
	var acts = action["move"]
	player.ai_input.x = clamp(acts[0], -1.0, 1.0)
	player.ai_input.y = clamp(acts[1], -1.0, 1.0)
	var aim = Vector2(acts[2], acts[3])
	if aim.length_squared() > 0.1:
		player.ai_aim = aim.normalized()
	player.ai_should_shoot = player.ammo > 0 and acts[4] > 0.5


# === Helpers ===

func _find_nearest_in_group(group_name: String):
	var nearest = null
	var min_dist = 99999.0
	for node in get_tree().get_nodes_in_group(group_name):
		if is_instance_valid(node):
			var d = player.global_position.distance_to(node.global_position)
			if d < min_dist:
				min_dist = d
				nearest = node
	return nearest


# REW-4: Called when another agent kills a zombie
func on_team_kill() -> void:
	_pending_team_reward += 0.5


func reset_rl_state() -> void:
	current_episode_reward = 0.0
	_prev_base_health = 500.0
	_last_shot_hit = false
	_pending_team_reward = 0.0
	_milestones_awarded = [false, false, false, false]
