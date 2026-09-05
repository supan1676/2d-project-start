extends Node2D


func play_idle_animation():
	%AnimationPlayer.play("idle")


func play_walk_animation():
	%AnimationPlayer.play("walk")


func play(animation_name: String):
	if %AnimationPlayer.has_animation(animation_name):
		%AnimationPlayer.play(animation_name)
	else:
		# Fallback to idle if animation is missing from the sprite
		%AnimationPlayer.play("idle")
