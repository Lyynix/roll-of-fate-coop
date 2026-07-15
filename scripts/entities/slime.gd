class_name Slime
extends BaseEnemy

## Welches Feld der Slime als nächstes betreten wird (oder ZERO, falls noch
## keins berechnet wurde / kein freies Feld verfügbar war). Wird sowohl für
## die tatsächliche Bewegung als auch für predict() genutzt - die rote
## Gefahren-Markierung zeigt also exakt das Feld, das im nächsten Zug
## tatsächlich betreten wird.
var next_move: Vector3i = Vector3i.ZERO

@export var trace_scene: PackedScene


func _on_ready() -> void:
	cooldown_max = 2  # bewegt sich nur jede 2. Runde
	spawn_cost = 3


func _execute_turn() -> void:
	if next_move == Vector3i.ZERO:
		_generate_move()

	# Die Spur entsteht an der ALTEN Position, also vor der Bewegung.
	spawn_trace(Vector3i(global_position))

	await move_to_grid(Vector3i(global_position) + next_move)

	_generate_move()
	start_cooldown()


## Bewusst öffentlich: wird für den Koop-Sync auch von
## GameManager._handle_enemy_turn_result() direkt auf der lokalen
## Slime-Instanz des Secondary aufgerufen (siehe dort), damit derselbe
## Dedup-Check (kein doppelter Trail) auf beiden Geräten identisch greift,
## ohne die Logik zweimal zu pflegen.
func spawn_trace(pos: Vector3i) -> void:
	# Kein Trail spawnen wenn schon einer da liegt
	if GameManager.get_entity_at(pos) != null:
		return

	var trail = trace_scene.instantiate()
	get_tree().current_scene.add_child(trail)
	trail.global_position = Vector3(pos)


## Während des Cooldowns (siehe BaseEnemy) zieht der Slime in diesem Zug gar
## nicht - die Vorhersage muss das widerspiegeln, sonst würde ein rotes
## Feld angezeigt, das diese Runde gar nicht bedroht ist. cooldown_current
## wird zu Beginn von take_turn() bereits um 1 verringert, bevor geprüft
## wird ob noch reloaded wird - bei <= 1 zieht der Slime im nächsten Zug
## also tatsächlich (siehe dieselbe Logik bei Sniper/Bully).
func predict() -> Array[Vector3i]:
	if cooldown_current > 1:
		return []
	if next_move == Vector3i.ZERO:
		return []
	return [Vector3i(global_position) + next_move]


## Wählt zufällig eine der vier Himmelsrichtungen, die zu einem begehbaren
## UND unbesetzten Feld führt (keine Wand, kein Spieler, kein anderer
## Gegner) - sonst würde der Slime sichtbar mit ihnen überlappen, da seine
## Bewegung (anders als z.B. bei Bully/Bomber) bisher keine Belegung prüfte.
func _generate_move() -> void:
	var dirs: Array[Vector3i] = [
		Vector3i.FORWARD,
		Vector3i.BACK,
		Vector3i.LEFT,
		Vector3i.RIGHT
	]

	var current_pos := Vector3i(global_position)
	var valid_dirs := dirs.filter(func(dir: Vector3i):
		var target: Vector3i = current_pos + dir
		if not LevelManager.is_walkable(Vector2i(target.x, target.z)):
			return false
		if GameManager.get_enemy_at(target) != null:
			return false
		for p in GameManager.get_players():
			if Vector3i(p.global_position) == target:
				return false
		return true
	)

	next_move = valid_dirs.pick_random() if not valid_dirs.is_empty() else Vector3i.ZERO
