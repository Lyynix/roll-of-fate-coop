class_name Sniper
extends BaseEnemy

const RANGE := 4
const DAMAGE := 1
const REACTION_TURNS := 2  # so viele Runden in Folge im Zielbereich nötig, bevor geschossen wird

const SHOT_SCENE: PackedScene = preload("res://scenes/map_elements/sniper_shot.tscn")
const AIM_TWEEN_DURATION := 0.25
## Feste Zielzeit für den Schuss-Partikel bis zum Ziel, unabhängig von der
## tatsächlichen Distanz (bis zu RANGE Felder) - sollte zur lifetime in
## sniper_shot.tscn passen, sonst verschwindet der Partikel vor dem Ziel.
const SHOT_TRAVEL_TIME := 0.4

var _turns_in_range := 0

@onready var barrel_pivot: Node3D = $BarrelPivot

## Wen der Lauf gerade anvisiert (oder null, wenn er senkrecht steht) - wird
## JEDEN Frame neu berechnet (siehe _update_barrel()), rein aus bereits
## synchronem Zustand (Cooldown/Spielerpositionen/Sichtlinie), läuft daher
## unverändert auf Host UND Secondary, ohne dass das übers Netzwerk
## abgeglichen werden müsste.
var _current_aim_target: Node3D = null
var _aim_tween: Tween = null

## Koop: ob in diesem Zug tatsächlich geschossen wurde - im Gegensatz zum
## Zielen selbst (siehe oben) ist das ECHTE Schuss-Ereignis (Schaden +
## Partikel) nur auf dem Host real, muss also für den Secondary relayt
## werden (siehe GameManager._build_enemy_turn_result()/consume_just_fired()).
var _just_fired: bool = false


func _on_ready() -> void:
	cooldown_max = 3
	spawn_cost = 3


func _process(_delta: float) -> void:
	_update_barrel()


## Bewegt sich nicht. Braucht REACTION_TURNS Runden in Folge mit dem Spieler
## im Radius UND freier Schussbahn, bevor geschossen wird - das gibt dem
## Spieler eine Reaktionszeit, um aus der Gefahrenzone zu fliehen.
func _execute_turn() -> void:
	var in_range := get_distance_to_player() <= RANGE and _has_los_to_player()

	if in_range:
		_turns_in_range += 1
	else:
		_turns_in_range = 0

	if _turns_in_range >= REACTION_TURNS:
		print("[", name, "] Schuss auf Spieler!")
		GameManager.damage_player(DAMAGE)
		_just_fired = true
		play_shot_effect()
		_turns_in_range = 0
		start_cooldown()


func _execute_cooldown_turn() -> void:
	_turns_in_range = 0


func _has_los_to_player() -> bool:
	var target := GameManager.nearest_player_to(global_position)
	if target == null:
		return false
	var origin := Vector2i(global_position.x, global_position.z)
	var player_pos := Vector2i(target.global_position.x, target.global_position.z)
	return LevelManager.has_line_of_sight(origin, player_pos)


## Läuft unabhängig vom eigenen Zug JEDEN Frame - reagiert dadurch sofort,
## sobald ein Spieler in Sichtweite kommt, statt erst wenn der Scharfschütze
## selbst an der Reihe ist. Zielt nur, solange er auch tatsächlich
## feuerbereit ist (kein Cooldown) - genau wie beim echten Schuss geht das
## Rohr nach dem Feuern (Cooldown startet) wieder senkrecht, bis er erneut
## bereit ist UND einen Spieler entdeckt.
func _update_barrel() -> void:
	var target: Node3D = null
	if cooldown_current <= 0:
		var candidate := GameManager.nearest_player_to(global_position)
		if candidate != null and get_distance_to_player() <= RANGE and _has_los_to_player():
			target = candidate

	if target == _current_aim_target:
		return
	_current_aim_target = target

	var target_quat := Quaternion.IDENTITY
	if target != null:
		var dir := target.global_position - global_position
		dir.y = 0.0
		if dir.length() > 0.01:
			target_quat = Quaternion(_basis_with_y(dir))

	if _aim_tween and _aim_tween.is_running():
		_aim_tween.kill()
	_aim_tween = create_tween()
	_aim_tween.tween_property(barrel_pivot, "quaternion", target_quat, AIM_TWEEN_DURATION)


## Baut eine Basis, deren lokale +Y-Achse exakt auf dir zeigt (X/Z beliebig,
## solange orthonormal - der Lauf ist um seine eigene Achse nicht
## richtungsabhängig). Analog zu FlamethrowerFace._basis_with_x(), nur für
## die Y- statt X-Achse, da der Lauf im Ruhezustand senkrecht (lokal +Y) steht.
static func _basis_with_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := y.cross(Vector3.UP).normalized()
	var z := x.cross(y)
	return Basis(x, y, z)


## Rein visuell: roter Partikel vom Lauf zum aktuell anvisierten Ziel. Läuft
## lokal beim tatsächlichen Feuern (Host, siehe _execute_turn()) UND wird
## für den Secondary über das relayte "fired"-Flag ausgelöst (siehe
## GameManager._handle_enemy_turn_result()) - zielt dort auf das eigene,
## unabhängig aber identisch berechnete _current_aim_target, es muss also
## keine Zielposition mitgeschickt werden.
func play_shot_effect() -> void:
	if _current_aim_target == null:
		return

	SoundManager.play_sfx("shot")

	var tip := barrel_pivot.global_position + barrel_pivot.global_transform.basis.y
	var to_target := _current_aim_target.global_position - tip
	var distance := to_target.length()
	if distance < 0.01:
		return

	var shot := SHOT_SCENE.instantiate()
	get_tree().current_scene.add_child(shot)
	shot.global_position = tip
	shot.configure(to_target.normalized(), distance / SHOT_TRAVEL_TIME)


## Für GameManager: liefert zurück ob in diesem Zug geschossen wurde und
## setzt das Flag zurück, damit es nicht in einem späteren Zug fälschlich
## nochmal gemeldet wird.
func consume_just_fired() -> bool:
	var result := _just_fired
	_just_fired = false
	return result


## Zeigt nur die Felder im Radius mit freier Schussbahn an, sobald im
## nächsten Zug wieder geschossen werden kann (cooldown_current wird zu
## Beginn von take_turn() um 1 verringert, bevor geprüft wird ob noch
## reloaded wird - bei <= 1 ist die Waffe im nächsten Zug also wieder
## feuerbereit).
func predict() -> Array[Vector3i]:
	if cooldown_current > 1:
		return []

	var tiles: Array[Vector3i] = []
	var origin := Vector3i(global_position)
	var origin_2d := Vector2i(origin.x, origin.z)

	for dx in range(-RANGE, RANGE + 1):
		for dz in range(-RANGE, RANGE + 1):
			if absi(dx) + absi(dz) > RANGE:
				continue
			var tile_2d := origin_2d + Vector2i(dx, dz)
			if not LevelManager.is_walkable(tile_2d):
				continue
			if not LevelManager.has_line_of_sight(origin_2d, tile_2d):
				continue
			tiles.append(origin + Vector3i(dx, 0, dz))

	return tiles


## Statt jedes bedrohte Feld einzeln zu markieren (Basisklasse): nur der
## Umriss der Gefahrenzone, siehe BaseEnemy._spawn_outline_particles().
func show_prediction() -> void:
	hide_prediction()
	_spawn_outline_particles(predict())
