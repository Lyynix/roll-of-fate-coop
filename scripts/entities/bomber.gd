class_name Bomber
extends BaseEnemy

const BOMB_SCENE: PackedScene = preload("res://scenes/map_elements/bomb.tscn")

func _on_ready() -> void:
	cooldown_max = 6
	spawn_cost = 5


## Weicht aus, lässt danach (alle 6 Runden) eine Bombe fallen.
func _execute_turn() -> void:
	await try_move_one_step(-get_direction_to_player())
	_drop_bomb()
	start_cooldown()


## Weicht auch während des Nachladens aktiv aus, statt stehenzubleiben.
func _execute_cooldown_turn() -> void:
	await try_move_one_step(-get_direction_to_player())


func _drop_bomb() -> void:
	var bomb := BOMB_SCENE.instantiate()
	get_tree().current_scene.add_child(bomb)
	bomb.global_position = global_position
