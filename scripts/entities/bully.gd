class_name Bully
extends BaseEnemy

const MAX_RANGE := 50
const STREAM_SCENE: PackedScene = preload("res://scenes/map_elements/directional_stream.tscn")

func _on_ready() -> void:
	cooldown_max = 3
	spawn_cost = 4


## Bewegt sich normalerweise 1 Feld auf den Spieler zu. Sobald X- oder
## Z-Achse mit dem Spieler übereinstimmen, stürmt er stattdessen geradeaus
## auf ihn zu.
func _execute_turn() -> void:
	if shares_axis_with_player():
		await _charge()
	else:
		await try_move_one_step(get_direction_to_player())


## Zweiphasiger Sturm: erst beschleunigt der Bully auf den Spieler zu
## (Phase A), und sobald er ihn erreicht, übernimmt der Spieler ohne eigene
## Anlaufzeit dieselbe (volle) Geschwindigkeit - beide rutschen gemeinsam
## bis zum nächsten Hindernis und bleiben dort abrupt stehen (Phase B).
func _charge() -> void:
	var dir := get_direction_to_player()
	if dir == Vector3i.ZERO:
		return

	# Zielwahl (nächster Spieler) einmal hier bestimmen und konsequent bis
	# _push_together() durchreichen - shares_axis_with_player()/
	# get_direction_to_player() haben denselben Spieler bereits als Ziel
	# gewählt (siehe enemy.gd), hier nur noch die konkrete Instanz nachschlagen.
	var player := GameManager.nearest_player_to(global_position) as Player
	var start := Vector3i(global_position)
	var player_pos := Vector3i(player.global_position)

	# Phase A: Anlauf bis direkt vor den Spieler (nicht auf sein Feld).
	# Nutzt absichtlich NICHT LevelManager.furthest_walkable(): das
	# Spielerfeld selbst ist begehbar (keine Wand), der Anlauf muss aber
	# genau davor stoppen statt hindurchzulaufen - eine reine
	# Wand-Kollisionsprüfung reicht hier also nicht.
	var approach_target := start
	var reached_player := false
	for i in range(1, MAX_RANGE):
		var candidate := start + dir * i
		if candidate == player_pos:
			reached_player = true
			break
		if not LevelManager.is_walkable(Vector2i(candidate.x, candidate.z)):
			break
		approach_target = candidate

	if approach_target != start:
		await _move_accelerating(approach_target)

	if not reached_player:
		return

	# Phase B: gemeinsamer Schub mit konstanter Geschwindigkeit bis zum
	# nächsten Hindernis hinter dem Spieler.
	print("[", name, "] Rammt den Spieler!")
	var push_furthest := LevelManager.furthest_walkable(player_pos, dir)
	var bully_push_target := push_furthest - dir
	await _push_together(player, bully_push_target, push_furthest)

	start_cooldown()


## Phase A: beschleunigte Anfahrt (Ease-In) zum Zielfeld.
func _move_accelerating(target: Vector3i) -> void:
	if not is_visible_to_camera():
		global_position = Vector3(target)
		return

	var distance := Vector3(target).distance_to(global_position)
	if distance <= 0.0 or move_speed <= 0.0:
		global_position = Vector3(target)
		return

	var tween := create_tween()
	tween.tween_property(self, "global_position", Vector3(target), distance / move_speed)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished


## Phase B: Bully und Spieler bewegen sich parallel mit konstanter (voller)
## Geschwindigkeit - der Spieler übernimmt also exakt das Tempo, mit dem
## der Bully gerade ankam, statt selbst zu beschleunigen - und stoppen am
## Ende abrupt (kein Ease-Out).
func _push_together(player: Player, bully_target: Vector3i, player_target: Vector3i) -> void:
	var distance := Vector3(player_target).distance_to(player.global_position)
	if distance <= 0.0 or move_speed <= 0.0:
		player.global_position = Vector3(player_target)
		global_position = Vector3(bully_target)
		return

	var duration := distance / move_speed

	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "global_position", Vector3(bully_target), duration)\
		.set_trans(Tween.TRANS_LINEAR)
	tween.tween_property(player, "global_position", Vector3(player_target), duration)\
		.set_trans(Tween.TRANS_LINEAR)
	await tween.finished


## Wie weit (in Feldern) die Sturm-Gefahrenzone in jede der 4 Richtungen
## reicht, sobald im nächsten Zug wieder gestürmt werden könnte. Richtungen
## ohne freies Nachbarfeld tauchen gar nicht erst im Dictionary auf.
## Gemeinsame Grundlage für predict() (Logik) und show_prediction()
## (Partikel-Stream pro Richtung, siehe DirectionalStream.configure()).
func _predict_ranges() -> Dictionary:
	if cooldown_current > 1:
		return {}

	var current := Vector3i(global_position)
	var directions: Array[Vector3i] = [Vector3i.FORWARD, Vector3i.BACK, Vector3i.LEFT, Vector3i.RIGHT]
	var ranges := {}

	for dir in directions:
		var count := 0
		for i in range(1, MAX_RANGE):
			var candidate := current + dir * i
			if not LevelManager.is_walkable(Vector2i(candidate.x, candidate.z)):
				break
			count += 1
		if count > 0:
			ranges[dir] = count

	return ranges


## Zeigt die komplette Reihe/Spalte durch die aktuelle Position als
## Gefahrenzone, sobald im nächsten Zug wieder gestürmt werden könnte.
func predict() -> Array[Vector3i]:
	var current := Vector3i(global_position)
	var tiles: Array[Vector3i] = []

	var ranges := _predict_ranges()
	for dir in ranges:
		for i in range(1, ranges[dir] + 1):
			tiles.append(current + dir * i)

	return tiles


## Statt einzelner Tile-Marker (Basisklasse) ein Partikel-Stream pro
## bedrohter Richtung: spawnt an der unteren Kante des Bullys und fliegt
## bis zum nächsten Hindernis - markiert also exakt dieselben Felder wie
## predict(), nur als fließender Strom statt diskreter Punkte.
func show_prediction() -> void:
	hide_prediction()

	var ranges := _predict_ranges()
	for dir in ranges:
		var stream := STREAM_SCENE.instantiate()
		get_tree().current_scene.add_child(stream)
		stream.global_position = global_position
		stream.configure(Vector3(dir), float(ranges[dir]))
		_prediction_markers.append(stream)
