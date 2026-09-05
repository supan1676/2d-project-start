extends RefCounted
class_name Blackboard
# Blackboard.gd — 88-float observation vector for RL
# Changes: OBS-1 (32 rays), OBS-2 (reload_progress), OBS-3 (ally), OBS-4 (no panic)

var volatile = {
	"velocity": Vector2.ZERO,
	"linear_speed": 0.0,
	"facing_dir": Vector2.RIGHT,
	"nearest_enemy_dir": Vector2.ZERO,
	"nearest_enemy_dist": 1.0,
	"base_dir": Vector2.ZERO,
	"base_dist": 1.0,
	"base_health_norm": 1.0,
	"is_shooting": false,
	"is_hitting_wall": false,
	"is_on_navigation_path": false,
	"nearest_item_dir": Vector2.ZERO,
	"nearest_item_dist": 1.0,
	"nearest_target_pos": Vector2.ZERO,
	"zombie_count_norm": 0.0,
	# OBS-1: dual-ring raycasts
	"long_rays": [],    # 16 entries of [dist, type]
	"short_rays": [],   # 16 entries of [dist, type]
	# OBS-3: ally awareness
	"nearest_ally_dir": Vector2.ZERO,
	"nearest_ally_dist": 1.0,
	"nearest_ally_health": 0.0,
	"allies_alive_norm": 0.0,
}

var state = {
	"health": 100.0,
	"ammo": 30,
	"max_ammo": 30,
	# OBS-2: continuous reload progress (was binary is_reloading)
	"reload_progress": 0.0,
}

var cognitive = {
	"aggressiveness": 0.5,
	# OBS-4: panic_level REMOVED — network derives threat from raw inputs
}


func update_volatile(key: String, value) -> void:
	volatile[key] = value

func update_state(key: String, value) -> void:
	state[key] = value

func update_cognitive(key: String, value) -> void:
	cognitive[key] = value


# === Observation Vector: 88 floats ===
# [0-31]   16 long-range rays × (dist, type)  = 32
# [32-63]  16 short-range rays × (dist, type) = 32
# [64]     health
# [65]     ammo
# [66]     reload_progress (OBS-2)
# [67-68]  velocity x,y
# [69-70]  facing dir x,y
# [71-72]  base dir x,y
# [73]     base distance
# [74]     base health
# [75-76]  enemy dir x,y
# [77]     enemy distance
# [78]     zombie count
# [79-80]  item dir x,y
# [81]     item distance
# [82]     aggressiveness
# [83]     nearest ally distance (OBS-3)
# [84-85]  nearest ally dir x,y (OBS-3)
# [86]     allies alive norm (OBS-3)
# [87]     nearest ally health (OBS-3)
func get_normalized_observations() -> Array:
	var obs = []

	# Long-range raycasts [0-31]
	for ray in volatile.long_rays:
		obs.append(ray[0])
		obs.append(ray[1])

	# Short-range raycasts [32-63]
	for ray in volatile.short_rays:
		obs.append(ray[0])
		obs.append(ray[1])

	# State [64-66]
	obs.append(state.health / 100.0)
	obs.append(float(state.ammo) / float(state.max_ammo))
	obs.append(state.reload_progress)  # OBS-2

	# Proprioception [67-70]
	var max_speed = 500.0
	obs.append(clamp(volatile.velocity.x / max_speed, -1.0, 1.0))
	obs.append(clamp(volatile.velocity.y / max_speed, -1.0, 1.0))
	obs.append(volatile.facing_dir.x)
	obs.append(volatile.facing_dir.y)

	# Base [71-74]
	obs.append(volatile.base_dir.x)
	obs.append(volatile.base_dir.y)
	obs.append(volatile.base_dist)
	obs.append(volatile.base_health_norm)

	# Enemy [75-77]
	obs.append(volatile.nearest_enemy_dir.x)
	obs.append(volatile.nearest_enemy_dir.y)
	obs.append(volatile.nearest_enemy_dist)

	# Threat [78]
	obs.append(volatile.zombie_count_norm)

	# Item [79-81]
	obs.append(volatile.nearest_item_dir.x)
	obs.append(volatile.nearest_item_dir.y)
	obs.append(volatile.nearest_item_dist)

	# Cognitive [82] — OBS-4: only aggressiveness, no panic
	obs.append(cognitive.aggressiveness)

	# OBS-3: Ally awareness [83-87]
	obs.append(volatile.nearest_ally_dist)
	obs.append(volatile.nearest_ally_dir.x)
	obs.append(volatile.nearest_ally_dir.y)
	obs.append(volatile.allies_alive_norm)
	obs.append(volatile.nearest_ally_health)

	return obs
