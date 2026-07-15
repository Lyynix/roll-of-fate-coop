class_name TurretFace
extends BaseFace

const TURRET_BURST_SCENE: PackedScene = preload("res://scenes/map_elements/turret_burst.tscn")

func activate() -> void:
	super.activate()
	_fire()


## Feuert aus jeder EmitPoint-Node der Szene einen Schuss - deren lokale
## X-Achse legt fest, in welche Gitter-Richtung von dort aus geschossen wird
## (siehe BaseFace.get_emit_points()). Sound + Partikel nur bei tatsächlichem
## Treffer, sonst würde bei jeder Aktivierung (auch ins Leere) unnötig oft
## das Schuss-Geräusch kommen.
func _fire() -> void:
	var player := owner_player
	var origin := Vector3i(player.global_position)
	for emit_point in get_emit_points():
		var dir := snap_to_cardinal(emit_point.global_transform.basis.x)
		var enemy := GameManager.get_enemy_at(origin + dir)
		if enemy == null:
			continue
		_spawn_burst(emit_point.global_position, Vector3(dir))
		enemy.take_damage(enemy.hp)


func _spawn_burst(origin: Vector3, dir: Vector3) -> void:
	SoundManager.play_sfx("shot")
	var burst := TURRET_BURST_SCENE.instantiate()
	owner_player.get_tree().current_scene.add_child(burst)
	burst.global_position = origin
	burst.configure(dir, 4.0)
