extends Node2D
# gun.gd — Weapon with fire-rate cooldown, muzzle flash, recoil
# OBS-2: Exposes reload_time_remaining and reload_duration for progress tracking

const BULLET = preload("res://bullet.tscn")
const MUZZLE_FLASH = preload("res://pistol/muzzle_flash/muzzle_flash.tscn")
const FIRE_RATE = 0.2

@onready var shooting_point = %ShootingPoint
@onready var pistol_sprite = $weapon/Pistol

var _cooldown = 0.0

# OBS-2: Reload tracking vars (written by SmartSoldier, read by RL_Controller)
var reload_time_remaining: float = 0.0
var reload_duration: float = 4.5  # Must match SmartSoldier.RELOAD_TIME


func _physics_process(delta: float) -> void:
	if _cooldown > 0:
		_cooldown -= delta
	# OBS-2: Countdown reload timer each frame
	if reload_time_remaining > 0:
		reload_time_remaining = max(0.0, reload_time_remaining - delta)


func shoot(shooter_ref = null) -> void:
	if shooting_point == null or _cooldown > 0:
		return

	# Ammo check
	if shooter_ref and "ammo" in shooter_ref:
		if shooter_ref.ammo <= 0:
			return
		shooter_ref.ammo -= 1

	# Muzzle flash
	var flash = MUZZLE_FLASH.instantiate()
	shooting_point.add_child(flash)

	# Recoil animation
	var tween = create_tween()
	tween.tween_property(pistol_sprite, "position:x", 92.0, 0.05).set_ease(Tween.EASE_OUT)
	tween.tween_property(pistol_sprite, "position:x", 112.0, 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

	# Screenshake
	var game = get_tree().get_first_node_in_group("game_manager")
	if game:
		game.apply_screenshake(5.0, 0.1)

	# Spawn bullet in world space
	var bullet = BULLET.instantiate()
	bullet.global_position = shooting_point.global_position
	bullet.global_rotation = shooting_point.global_rotation
	if shooter_ref:
		bullet.shooter_agent = shooter_ref
	get_tree().current_scene.add_child(bullet)

	_cooldown = FIRE_RATE


# OBS-2: Called by SmartSoldier when reload starts
func start_reload_tracking() -> void:
	reload_time_remaining = reload_duration
