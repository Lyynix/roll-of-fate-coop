class_name BaseEnemy
extends Node3D
## Basisklasse für alles, was einen eigenen Zug hat (Slime, Sniper, Bully,
## Bomber, Bombe). Definiert den Zug-Lebenszyklus (take_turn() -> Cooldown ->
## _execute_turn()), HP/Schaden/Tod, die Gefahren-Vorschau (predict()/
## show_prediction()) sowie geteilte Bewegungs- und Zielwahl-Helfer.


@export var max_hp: int = 1
@export var grid_size: float = 1.0
@export var move_speed: float = 4.0
## Punktekosten im Spawn-Budget - maßgeblich für die Level-Generierung ist
## LevelManager.ENEMY_COSTS; dieser Wert hier muss dazu passen (wird von der
## Test-Suite zum Nachrechnen des Budgets genutzt).
@export var spawn_cost: int = 2


var hp: int
var is_dead: bool = false

## Koop: stabile ID für den Gegner-Zug-Sync (siehe GameManager._begin_enemy_turn()/
## _handle_enemy_turn_result()) - bleibt über mehrere Züge hinweg gültig, anders
## als ein Array-Index, der sich durch Tode/Neuzugänge verschiebt. -1 = noch
## keine vergeben, wird dann automatisch beim Registrieren zugewiesen (siehe
## GameManager.register_enemy()).
var sync_id: int = -1

# Cooldown: Subklassen setzen cooldown_max, Basis zählt runter
var cooldown_current: int = 0
@export var cooldown_max: int = 0            # 0 = kein Cooldown

## Aktuell angezeigte Gefahren-Marker (siehe show_prediction()/hide_prediction()).
var _prediction_markers: Array[Node3D] = []


func _ready() -> void:
	hp = max_hp
	GameManager.register_enemy(self)
	_on_ready()


## Überschreibbar für Subklassen-Setup (statt _ready override)
func _on_ready() -> void:
	pass


## Wird vom GameManager aufgerufen und direkt awaited - das Zug-Ende wird
## allein über das Zurückkehren der Coroutine gemeldet, bewusst ohne
## separates Signal (das bei synchron abgeschlossenen Zügen verpasst werden
## könnte, siehe GameManager._begin_enemy_turn()).
## NICHT überschreiben – stattdessen _execute_turn().
func take_turn() -> void:
	if is_dead:
		return

	# Cooldown runterzählen
	if cooldown_current > 0:
		cooldown_current -= 1
		_on_cooldown_tick(cooldown_current)

		# Wenn noch im Cooldown: nur Idle-Verhalten, kein normaler Zug
		if cooldown_current > 0:
			await _execute_cooldown_turn()
			return

	await _execute_turn()


## Hauptlogik des Zugs – in Subklassen überschreiben.
func _execute_turn() -> void:
	pass


## Wird ausgeführt wenn der Gegner im Cooldown ist – optional überschreiben.
## Z.B. Sniper zeigt Reload-Animation, ... 
func _execute_cooldown_turn() -> void:
	pass


## Cooldown starten (z.B. nach einem Angriff)
func start_cooldown() -> void:
	cooldown_current = cooldown_max


## Wird jeden Tick aufgerufen solange Cooldown läuft – optional überschreiben.
func _on_cooldown_tick(_remaining: int) -> void:
	pass


## Zeigt dem Spieler an, was der Gegner als nächstes tun wird.
## Gibt Array von Grid-Positionen zurück, die bedroht sind.
## Subklassen überschreiben dies.
func predict() -> Array[Vector3i]:
	return []


## Visuelle Threat-Marker ein-/ausblenden – wird vom GameManager gesteuert.
func show_prediction() -> void:
	hide_prediction()
	for tile in predict():
		var marker := GameManager.PREDICTION_SCENE.instantiate()
		get_tree().current_scene.add_child(marker)
		marker.global_position = Vector3(tile)
		_prediction_markers.append(marker)


## immediate=true: Marker werden sofort entfernt (für den Levelwechsel, wo
## ein langsames Ausklingen in eine bereits neu generierte Etage hinein
## verwirrend wirken würde, siehe LevelManager._clear_entities()).
## immediate=false (Normalfall, z.B. Rundenwechsel): bereits ausgestoßene
## Partikel klingen noch natürlich aus statt schlagartig zu verschwinden -
## es wird nur das Nachspawnen neuer Partikel gestoppt.
func hide_prediction(immediate: bool = false) -> void:
	for marker in _prediction_markers:
		if not is_instance_valid(marker):
			continue
		if immediate:
			marker.queue_free()
		else:
			_fade_out_marker(marker)
	_prediction_markers.clear()


func _fade_out_marker(marker: Node) -> void:
	var systems := _collect_particle_systems(marker)
	var max_lifetime := 0.0
	for system in systems:
		system.emitting = false
		max_lifetime = maxf(max_lifetime, system.lifetime)

	get_tree().create_timer(max_lifetime).timeout.connect(func():
		if is_instance_valid(marker):
			marker.queue_free()
	)


func _collect_particle_systems(node: Node) -> Array[GPUParticles3D]:
	var result: Array[GPUParticles3D] = []
	if node is GPUParticles3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_collect_particle_systems(child))
	return result


const EDGE_SEGMENT_SCENE: PackedScene = preload("res://scenes/map_elements/edge_segment.tscn")
const EDGE_SEGMENT_IDLE_SCENE: PackedScene = preload("res://scenes/map_elements/edge_segment_idle.tscn")

## Markiert nur den UMRISS einer Gefahrenzone mit Partikel-Liniensegmenten,
## nicht die volle Fläche - ein Segment pro Kante zwischen einem Feld aus
## tiles und einem Nachbarn, der NICHT in tiles enthalten ist (egal ob das
## ein normales, unbedrohtes Feld oder eine Wand ist - Wände sind schlicht
## nie Teil von tiles). Von Sniper und Bomb genutzt (siehe deren
## show_prediction()-Overrides). Pro Kante zwei Systeme: eins bleibt (wie
## ursprünglich) ortsfest auf der Kante, damit der genaue Umriss klar
## erkennbar bleibt, das andere fliegt zusätzlich zur Gefahrenquelle.
func _spawn_outline_particles(tiles: Array[Vector3i]) -> void:
	var tile_set := {}
	for t in tiles:
		tile_set[Vector2i(t.x, t.z)] = true

	# [Nachbar-Versatz, verläuft die Kante entlang der lokalen X-Achse?]
	var edges := [
		[Vector2i(0, -1), true],
		[Vector2i(0, 1), true],
		[Vector2i(1, 0), false],
		[Vector2i(-1, 0), false],
	]

	for t in tiles:
		var t2d := Vector2i(t.x, t.z)
		for edge in edges:
			var offset : Vector2i = edge[0]
			var along_x : bool = edge[1]
			if tile_set.has(t2d + offset):
				continue # Nachbar ebenfalls bedroht - keine Umriss-Kante hier

			var segment_pos := Vector3(t.x, 0.02, t.z) + Vector3(offset.x, 0, offset.y) * 0.5
			var segment_rotation_y := 0.0 if along_x else PI / 2.0

			var idle := EDGE_SEGMENT_IDLE_SCENE.instantiate()
			get_tree().current_scene.add_child(idle)
			idle.global_position = segment_pos
			idle.rotation.y = segment_rotation_y
			_prediction_markers.append(idle)

			var segment := EDGE_SEGMENT_SCENE.instantiate()
			get_tree().current_scene.add_child(segment)
			segment.global_position = segment_pos
			segment.rotation.y = segment_rotation_y

			# Partikel fliegen zurück zur Quelle der Gefahrenzone (Sniper/
			# Bombe), nicht ziellos vom Rand weg.
			var flow_dir := Vector3(global_position.x, 0, global_position.z) - Vector3(segment_pos.x, 0, segment_pos.z)
			segment.configure(flow_dir)

			_prediction_markers.append(segment)


func take_damage(amount: int) -> void:
	if is_dead: return

	hp -= amount
	print("[", name, "] Schaden: ", amount, " → HP: ", hp, "/", max_hp)
	_on_damage(amount)

	if hp <= 0:
		# Belohnung fürs "echte" Töten über Schaden (Turret, Flammenwerfer,
		# Dash-Aufprall, ...) - bewusst NICHT in die() selbst, da die
		# Slime-Falle Gegner direkt über die() tötet, ohne take_damage() zu
		# durchlaufen, und dafür explizit weder Heilung noch Punkte geben
		# soll (Rammen ist kein "Kill" im Sinne der Wertung).
		GameManager.heal_player(1)
		GameManager.add_score(30)
		die()


## Visuelle Reaktion auf Schaden – optional überschreiben (Flash, Partikel etc.)
func _on_damage(_amount: int) -> void:
	pass


func die() -> void:
	if is_dead: return
	is_dead = true
	SoundManager.play_sfx("kill_enemy")

	# Direkte die()-Aufrufe (z.B. Slime-Ramm-/Tret-Falle) gehen nicht über
	# take_damage() und damit auch nicht über die normale Zugfolge, in der
	# hide_prediction() sonst beim nächsten Gegner-Zug aufräumt - ohne
	# diesen Aufruf hier würde z.B. die rote Vorschau-Markierung einer
	# gerammten Slime für immer stehen bleiben.
	hide_prediction()

	print("[", name, "] stirbt!")
	GameManager.unregister_enemy(self)

	await _on_death()
	queue_free()


## Death-Animation – optional überschreiben.
func _on_death() -> void:
	# Default: kurzes Schrumpfen
	var tween = create_tween()
	tween.tween_property(self, "scale", Vector3.ZERO, 0.3)
	await tween.finished


## Bewegt den Gegner visuell und logisch zu einem neuen Grid-Feld.
## Ist der Gegner aktuell nicht im Kamera-Sichtfeld, springt er sofort
## (keine Wartezeit für etwas, das der Spieler eh nicht sieht).
func move_to_grid(target: Vector3i) -> void:
	if not is_visible_to_camera():
		global_position = Vector3(target)
		return

	var tween = create_tween()
	tween.tween_property(self, "global_position", Vector3(target), 1.0 / move_speed)
	await tween.finished


## Prüft ob sich der Gegner aktuell im Sichtfeld der aktiven Kamera befindet.
func is_visible_to_camera() -> bool:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return true
	return camera.is_position_in_frustum(global_position)


## Versucht, genau ein Feld in Richtung dir zu ziehen. Bricht ab (keine
## Bewegung) wenn dir ZERO ist, das Zielfeld eine Wand/Säule ist, oder
## bereits durch den Spieler oder einen anderen Gegner belegt ist. Geteilte
## Basis für simple "1 Feld pro Zug"-Bewegungsmuster (Bully nähert sich an,
## Bomber weicht aus - exakt dieselbe Prüfung, nur mit gegensätzlichem dir).
func try_move_one_step(dir: Vector3i) -> void:
	if dir == Vector3i.ZERO:
		return

	var target := Vector3i(global_position) + dir
	if not LevelManager.is_walkable(Vector2i(target.x, target.z)):
		return
	if GameManager.get_enemy_at(target) != null:
		return
	for p in GameManager.get_players():
		if Vector3i(p.global_position) == target:
			return

	await move_to_grid(target)


## Grid-Position des jeweils NÄCHSTEN Spielers (Koop: zwei mögliche Ziele -
## siehe GameManager.nearest_player_to(); degradiert im Singleplayer zu "der
## eine Spieler"). Alle folgenden Helfer bauen darauf auf, bekommen die
## korrekte Zielwahl also automatisch mit.
func get_player_grid_pos() -> Vector3i:
	var target := GameManager.nearest_player_to(global_position)
	if target == null:
		return Vector3i.ZERO
	return Vector3i(target.global_position)

## Manhattan-Distanz zum nächsten Spieler
func get_distance_to_player() -> int:
	var player_pos = get_player_grid_pos()

	return absi(global_position.x - player_pos.x) + absi(global_position.z - player_pos.z)


## Richtung zum nächsten Spieler als Achsen-Einheitsvektor entlang der
## dominanten Achse (keine Diagonale)
func get_direction_to_player() -> Vector3i:
	var player_pos = get_player_grid_pos()
	var diff = player_pos - Vector3i(global_position)

	# Dominante Achse wählen
	if absi(diff.x) >= absi(diff.z):
		return Vector3i(signi(diff.x), 0, 0)
	else:
		return Vector3i(0, 0, signi(diff.z))


## Prüft ob eine Achse (X oder Z) mit dem nächsten Spieler geteilt wird
func shares_axis_with_player() -> bool:
	var player_pos = get_player_grid_pos()
	var own_pos = Vector3i(global_position)
	return own_pos.x == player_pos.x or own_pos.z == player_pos.z
