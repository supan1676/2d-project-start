extends Node
class_name SquadDialogue
# SquadDialogue.gd — Contextual squad callouts based on blackboard state

const COOLDOWN = 3.0

@onready var _player = get_parent()
var _last_bark_time = 0.0


func _process(_delta: float) -> void:
	var bb: Blackboard = _player.blackboard
	if bb == null:
		return
	if Time.get_unix_time_from_system() - _last_bark_time < COOLDOWN:
		return
	_evaluate(bb)


func _evaluate(bb: Blackboard) -> void:
	if bb.cognitive.panic_level > 0.8:
		_bark("NEGATIVE! WE'RE GETTING OVERRUN!")
	elif bb.state.is_reloading:
		_bark("RELOADING! COVER ME!")
	elif bb.state.ammo < 5 and not bb.state.is_reloading:
		_bark("WINCHESTER! I'M ALMOST DRY!")
	elif _player.just_took_damage:
		_bark("I'M HIT!")
	elif bb.volatile.nearest_enemy_dist > 0.01 and bb.volatile.nearest_enemy_dist < 0.3:
		_bark("CONTACT!")


func _bark(text: String) -> void:
	_last_bark_time = Time.get_unix_time_from_system()

	if _player._status_label:
		_player._status_label.text = text
		_player._status_label.visible = true

		var timer = get_tree().create_timer(2.0)
		timer.timeout.connect(func():
			if is_instance_valid(_player._status_label) and _player._status_label.text == text:
				_player._status_label.visible = false
		)
