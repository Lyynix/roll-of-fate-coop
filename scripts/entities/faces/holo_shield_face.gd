class_name HoloShieldFace
extends BaseFace

const SHIELD_SPHERE_SCENE: PackedScene = preload("res://scenes/map_elements/shield_sphere.tscn")

var _shield_effect: Node3D = null

func activate() -> void:
	super.activate()
	SoundManager.play_sfx("shield_activated")
	GameManager.activate_shield()
	_spawn_shield_effect()


## Wird aufgerufen wenn der Spieler die Schild-Seite abrollt (direkt vor der
## Roll-Animation). Stoppt neue Partikel-Emissionen; laufende Partikel
## klingen noch während der Roll-Animation natürlich aus.
func deactivate() -> void:
	super.deactivate()
	if is_instance_valid(_shield_effect):
		_shield_effect.stop()
	_shield_effect = null


func _spawn_shield_effect() -> void:
	# Falls die Seite erneut aktiviert wird ohne vorher deaktiviert zu werden
	if is_instance_valid(_shield_effect):
		_shield_effect.stop()
	_shield_effect = SHIELD_SPHERE_SCENE.instantiate()
	owner_player.get_tree().current_scene.add_child(_shield_effect)
	# Würfelmittelpunkt: Grid-Position (y=0) + halbe Würfelhöhe
	_shield_effect.global_position = owner_player.global_position + Vector3(0.0, 0.5, 0.0)
