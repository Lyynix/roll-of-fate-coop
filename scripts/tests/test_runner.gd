# test_runner.gd
#
# Headless ausführbare Regressions-Test-Suite für den kompletten Build.
# Aufruf (aus dem Projektverzeichnis):
#
#   godot --headless --path . scenes/tests/test_runner.tscn
#
# Exit-Code 0 = alle Tests bestanden, 1 = mindestens ein Fehlschlag - damit
# eignet sich der Aufruf auch für CI/Skripte. Die Main.tscn-Instanz als
# Kind-Node liefert eine echte Spielumgebung (Player, LevelParent); deren
# _ready() läuft vor unserer eigenen (Godot ruft Kinder vor Eltern auf),
# GameManager/LevelManager sind also schon initialisiert, wenn wir starten.
extends Node

@onready var main := $Main
var t := TestFramework.new()

## Schlichte Zahlen-Seiten (Index 0..5 = Slot 1..6), zum Neutralisieren des
## Würfels in Tests die reines 90°-Rollen brauchen - siehe _clear_all_faces().
const _PLAIN_FACE_SCENES: Array[PackedScene] = [
	preload("res://scenes/entities/faces/face_die_1.tscn"),
	preload("res://scenes/entities/faces/face_die_2.tscn"),
	preload("res://scenes/entities/faces/face_die_3.tscn"),
	preload("res://scenes/entities/faces/face_die_4.tscn"),
	preload("res://scenes/entities/faces/face_die_5.tscn"),
	preload("res://scenes/entities/faces/face_die_6.tscn"),
]


func _ready() -> void:
	await get_tree().process_frame

	await _test_level_generation()
	await _test_wall_and_enemy_blocking()
	await _test_deckbuilding()
	await _test_slime_trace_glue()
	await _test_slime_trap()
	await _test_turret()
	await _test_flamethrower()
	await _test_holo_shield()
	await _test_phase()
	await _test_dash()
	await _test_sniper()
	await _test_bully_charge()
	await _test_bomb()
	await _test_enemy_turn_no_skip_on_mid_loop_death()
	await _test_level_regenerate_cleanup()
	await _test_enemy_spawn_budget()
	await _test_network_manager_cleanup()
	await _test_level_serialization_roundtrip()

	t.print_summary()
	get_tree().quit(0 if t.all_passed() else 1)


## Setzt Etage, Spieler-HP/-Position und Status-Flags zwischen Testfällen
## zurück, damit sich Tests nicht gegenseitig beeinflussen. Würfelseiten
## werden NICHT pauschal zurückgesetzt - Tests, die eine bestimmte Seite
## brauchen, schalten sie sich selbst (slot_scene), analog zum manuellen
## Testen während der Entwicklung.
func _reset() -> void:
	GameManager.player_shielded = false
	GameManager.start_game()
	await get_tree().process_frame


func _player() -> Player:
	return GameManager.player as Player


## Ersetzt alle 6 Würfelseiten durch schlichte Zahlen-Seiten - Tests, die
## mehrere Rollen hintereinander als reine 90°-Einzelschritte erwarten (z.B.
## ein voller 360°-Zyklus zum Lösen einer Schleimspur), dürfen nicht zufällig
## auf eine modify_roll()-Fähigkeit (Phase/Dash) treffen, die einen Zug
## stattdessen übernimmt und dabei mehrere Felder auf einmal überspringt.
## Der Test-Spieler trägt standardmäßig eine Phase-Seite auf Slot 2 (siehe
## test_override_slot/test_override_scene in player.tscn, extra für die
## Phase-/Dash-Tests) - Tests, die reines Rollen brauchen, neutralisieren das
## hiermit explizit, statt sich auf Zufall zu verlassen.
func _clear_all_faces(player: Player) -> void:
	for slot_name in player.slots:
		player.slot_scene(player.slots[slot_name], _PLAIN_FACE_SCENES[slot_name - 1])


## Entfernt alle aktuell gespawnten (von _reset()/start_game() zufällig
## platzierten) Gegner - für Tests, die einen erzwungenen, freien Testpfad
## brauchen: ohne das könnte ein wild umherlaufender Slime gelegentlich auf
## genau diesen Pfad wandern und den Spieler wie eine Wand blockieren
## (hat z.B. _test_slime_trace_glue() flaky gemacht).
func _clear_enemies() -> void:
	for e in GameManager.enemies.duplicate():
		if is_instance_valid(e):
			GameManager.unregister_enemy(e)
			e.queue_free()


## Sucht eine in `dirs` priorisierte Richtung, die vom Spieler aus begehbar
## ist - die prozedural generierten Level sind nicht deterministisch, viele
## Tests brauchen aber irgendeine gültige Bewegungsrichtung.
func _open_direction(preferred: Vector3 = Vector3.FORWARD) -> Vector3:
	var player := _player()
	for d in [preferred, Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK, Vector3.LEFT]:
		var target := LevelManager.world_to_grid(player.global_position + d * player.grid_size)
		if LevelManager.is_walkable(target):
			return d
	return Vector3.ZERO


## Wartet bis der Spieler nach einem Zug wieder Eingaben annimmt (voller
## RESOLVING/ENEMY_TURN/PLAYER_TURN-Zyklus durchlaufen). guard_max begrenzt
## die Wartezeit, falls der Build hängt (siehe Regressionstest weiter
## unten) - ohne dieses Limit würde der gesamte Testlauf einfrieren.
func _wait_for_input(guard_max: int = 600) -> bool:
	var player := _player()
	var guard := 0
	while not player.awaiting_input and guard < guard_max:
		await get_tree().process_frame
		guard += 1
	return guard < guard_max


## Findet den Slot, der aktuell oben liegt (für Tests, die dem Würfel über
## slot_scene() gezielt eine bestimmte Fähigkeit aufsetzen wollen).
func _top_slot(player: Player) -> Marker3D:
	var found : Marker3D = null
	var max_y := -INF
	for slot_name in player.slots:
		var marker : Marker3D = player.slots[slot_name]
		if marker.global_position.y > max_y:
			max_y = marker.global_position.y
			found = marker
	return found


## Sucht rekursiv alle GPUParticles3D unter node (eigenständige Kopie von
## BaseEnemy._collect_particle_systems() für Tests, die auf bereits
## freigegebene Enemy-Instanzen keinen Methodenzugriff mehr haben).
func _find_particle_systems(node: Node) -> Array[GPUParticles3D]:
	var result: Array[GPUParticles3D] = []
	if node is GPUParticles3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_particle_systems(child))
	return result


# ════════════════════════════════════════════════════════════════════
#  Level-Generierung
# ════════════════════════════════════════════════════════════════════

func _test_level_generation() -> void:
	await _reset()
	t.begin("Level-Generierung")

	t.check(not LevelManager.grid.is_empty(), "Grid ist nach Generierung nicht leer")

	var start_cell := LevelManager.get_cell(LevelManager.start_position)
	var exit_cell := LevelManager.get_cell(LevelManager.exit_position)
	t.check(start_cell != null and start_cell.type == GridCell.Type.START, "Start-Zelle hat Typ START")
	t.check(exit_cell != null and exit_cell.type == GridCell.Type.EXIT, "Exit-Zelle hat Typ EXIT")
	t.check(LevelManager.start_position != LevelManager.exit_position, "Start und Exit sind unterschiedliche Felder")

	# Erreichbarkeit per Flood-Fill: garantiert laut Architektur (additiver
	# Aufbau, jeder Raum hängt an einem bereits verbundenen Raum), hier als
	# Regressionsschutz gegen zukünftige Änderungen am Generator.
	t.check(_is_reachable(LevelManager.start_position, LevelManager.exit_position),
		"Exit ist von Start aus über begehbare Felder erreichbar")


func _is_reachable(from: Vector2i, to: Vector2i) -> bool:
	var visited := {from: true}
	var queue: Array[Vector2i] = [from]
	var dirs : Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		if current == to:
			return true
		for d in dirs:
			var next := current + d
			if visited.has(next):
				continue
			if not LevelManager.is_walkable(next):
				continue
			visited[next] = true
			queue.append(next)

	return false


# ════════════════════════════════════════════════════════════════════
#  Bewegung: Wände und Gegner blockieren
# ════════════════════════════════════════════════════════════════════

func _test_wall_and_enemy_blocking() -> void:
	await _reset()
	t.begin("Wand- und Gegner-Blockierung")

	var player := _player()

	# Künstliche Wand direkt vor dem Spieler erzwingen.
	var wall_pos := LevelManager.world_to_grid(player.global_position + Vector3.FORWARD)
	LevelManager.grid[wall_pos] = GridCell.new(GridCell.Type.WALL)

	var pos_before := player.global_position
	player.roll(Vector3.FORWARD)
	await get_tree().process_frame
	t.check(player.global_position == pos_before, "Rollen gegen eine Wand bewegt den Spieler nicht")
	t.check(player.awaiting_input, "Zug an einer Wand wird nicht verbraucht")

	# Nicht-Slime-Gegner blockiert wie eine Wand, ohne Folgen.
	var dir := _open_direction()
	t.check(dir != Vector3.ZERO, "Es gibt eine offene Richtung für den Blockier-Test")
	if dir != Vector3.ZERO:
		var sniper : Sniper = preload("res://scenes/entities/sniper.tscn").instantiate()
		add_child(sniper)
		sniper.global_position = player.global_position + dir
		await get_tree().process_frame

		var pos_before2 := player.global_position
		player.roll(dir)
		await get_tree().process_frame
		t.check(player.global_position == pos_before2, "Rollen in einen Gegner bewegt den Spieler nicht")
		t.check(is_instance_valid(sniper), "Der gerammte Nicht-Slime-Gegner überlebt unbeschadet")
		sniper.queue_free()


# ════════════════════════════════════════════════════════════════════
#  Deckbuilding: attach_to_bottom() + FacePickup
# ════════════════════════════════════════════════════════════════════

func _test_deckbuilding() -> void:
	await _reset()
	t.begin("Deckbuilding (attach_to_bottom / FacePickup)")

	var player := _player()
	var before := player.get_bottom_face_module()
	var before_scene := before.source_scene

	var displaced := player.attach_to_bottom(preload("res://scenes/entities/faces/face_turret.tscn"))
	t.check(player.get_bottom_face_module() is TurretFace, "attach_to_bottom() setzt die neue Seite korrekt")
	t.check(displaced == before_scene, "attach_to_bottom() gibt die verdrängte Szene zurück")

	# FacePickup: simuliert das Überrollen eines Pickups direkt. Die
	# Unterseite ist inzwischen der gerade angebrachte Turret (nicht mehr
	# die ursprüngliche before_scene) - DAS ist die Seite, die jetzt
	# verdrängt und abgelegt werden muss.
	var turret_scene := player.get_bottom_face_module().source_scene
	var pickup : FacePickup = preload("res://scenes/map_elements/pickup_tile.tscn").instantiate()
	pickup.ability_scene = preload("res://scenes/entities/faces/face_holo_shield.tscn")
	add_child(pickup)
	pickup.global_position = player.global_position

	pickup.on_player_entered(player)
	await get_tree().process_frame

	t.check(player.get_bottom_face_module() is HoloShieldFace, "FacePickup bringt die neue Fähigkeit an")

	var found_dropped := false
	for child in main.level_parent.get_children():
		if child is FacePickup and child != pickup:
			found_dropped = child.ability_scene == turret_scene
	t.check(found_dropped, "Die verdrängte Seite wird als neues Pickup auf dem Feld abgelegt")


# ════════════════════════════════════════════════════════════════════
#  Schleimspur-Verklebung (strukturell über is_disabled())
# ════════════════════════════════════════════════════════════════════

func _test_slime_trace_glue() -> void:
	await _reset()
	t.begin("Schleimspur-Verklebung")

	var player := _player()

	# Keine zufällig gespawnten Gegner auf dem erzwungenen Testpfad (siehe
	# _clear_enemies()) und keine Phase-/Dash-Seite, die einen der folgenden
	# reinen 90°-Rollschritte überspringend übernehmen könnte (siehe
	# _clear_all_faces()) - VOR dem Ankleben der Spur, sonst würde
	# slot_scene() sie wieder entfernen.
	_clear_enemies()
	_clear_all_faces(player)

	# Garantiert freie Bahn von 5 Feldern in FORWARD-Richtung erzwingen,
	# damit der Test nicht vom zufälligen Level-Layout abhängt: ein voller
	# 360°-Zyklus (die geklebte Seite kommt wieder unten an) braucht
	# exakt 4 Rollen in DERSELBEN Richtung - bei einer durchs Layout
	# erzwungenen Richtungsänderung wäre das nicht mehr in 4 Zügen
	# garantiert (das hat den Test zuvor gelegentlich flaky gemacht).
	for i in range(5):
		LevelManager.grid[LevelManager.world_to_grid(player.global_position + Vector3.FORWARD * i)] = GridCell.new(GridCell.Type.FLOOR)

	var trace : Node3D = preload("res://scenes/map_elements/slime_trace.tscn").instantiate()
	add_child(trace)
	trace.global_position = player.global_position

	player.glue_to_bottom_face(trace)
	var glued_face := player.get_bottom_face_module()
	t.check(glued_face.is_disabled(), "Seite ist nach dem Ankleben strukturell deaktiviert")
	t.check(trace.get_parent() == glued_face.get_parent(), "Spur hängt am selben Slot wie die Seite")

	# Exakt 4x in dieselbe Richtung rollen = vollständiger 360°-Zyklus.
	var released := false
	for i in range(4):
		player.roll(Vector3.FORWARD)
		await _wait_for_input()
		if not is_instance_valid(trace) or trace.get_parent() != glued_face.get_parent():
			released = true
			break

	t.check(released, "Spur wird gelöst, sobald die Seite wieder Bodenkontakt hat")
	if is_instance_valid(glued_face):
		t.check(not glued_face.is_disabled(), "Seite ist danach wieder aktiv")


# ════════════════════════════════════════════════════════════════════
#  Slime-Falle: Rammen und Prognose-Feld betreten
# ════════════════════════════════════════════════════════════════════

func _test_slime_trap() -> void:
	await _reset()
	t.begin("Slime-Falle: Rammen")

	var player := _player()

	# Keine zufällig gespawnten Gegner auf dem erzwungenen Testpfad (siehe
	# _clear_enemies()) - der Ramm-Slime unten wird bewusst erst DANACH
	# manuell platziert. Ebenso keine Phase-/Dash-Seite, die einen der
	# Rollschritte in der Release-Schleife unten übernehmen könnte (siehe
	# _clear_all_faces()) - glue_all_faces() beim Rammen beklebt ohnehin
	# jede Seite unabhängig von ihrem Typ, das Neutralisieren vorher ändert
	# daran nichts.
	_clear_enemies()
	_clear_all_faces(player)

	# Garantiert freie Bahn von 5 Feldern erzwingen (siehe Begründung in
	# _test_slime_trace_glue): die Falle muss exakt wie eine normale
	# Schleimspur über einen vollen 360°-Zyklus (4 Rollen) wieder freigeben.
	for i in range(5):
		LevelManager.grid[LevelManager.world_to_grid(player.global_position + Vector3.FORWARD * i)] = GridCell.new(GridCell.Type.FLOOR)

	var slime : Slime = preload("res://scenes/entities/slime.tscn").instantiate()
	add_child(slime)
	slime.global_position = player.global_position + Vector3.FORWARD
	await get_tree().process_frame

	var bottom_before := player.get_bottom_face_module()

	# HP absichtlich unter das Maximum, um zu prüfen dass das Rammen
	# (Slime-Falle, kein "echter" Kill über Schaden) NICHT heilt.
	GameManager.player_hp = GameManager.max_player_hp - 1
	var hp_before_ram := GameManager.player_hp

	# Vorschau-Marker manuell erzeugen (normalerweise von GameManager beim
	# Rundenstart ausgelöst) und Referenz sichern - Regressionstest für den
	# gemeldeten Bug, dass die Markierung nach dem Rammen stehen blieb.
	# next_move muss dafür gesetzt sein, sonst liefert predict() noch leer.
	slime.next_move = Vector3i.LEFT
	slime.show_prediction()
	var markers_before := slime._prediction_markers.duplicate()

	player.roll(Vector3.FORWARD)
	await get_tree().process_frame
	await get_tree().process_frame

	var all_glued := true
	for slot_name in player.slots:
		var marker : Marker3D = player.slots[slot_name]
		if marker.get_child_count() > 0 and not marker.get_child(0).is_disabled():
			all_glued = false
	t.check(all_glued, "Alle Seiten sind nach dem Rammen verklebt (wie eine Schleimspur)")
	t.check(not is_instance_valid(slime) or slime.is_dead, "Der gerammte Slime stirbt")
	t.check(GameManager.player_hp == hp_before_ram, "Rammen (Slime-Falle) heilt NICHT")

	# Marker verschwinden jetzt nicht mehr schlagartig, sondern klingen aus:
	# bereits ausgestoßene Partikel dürfen weiterleben, es darf aber nichts
	# mehr NACHgespawnt werden (emitting == false auf allen enthaltenen
	# Partikelsystemen). slime selbst ist nach dem Rammen bereits
	# freigegeben, daher eine eigenständige Helper-Funktion statt der
	# (Instanz-gebundenen) BaseEnemy._collect_particle_systems().
	var markers_stopped := true
	for marker in markers_before:
		if not is_instance_valid(marker):
			continue
		for system in _find_particle_systems(marker):
			if system.emitting:
				markers_stopped = false
	t.check(not markers_before.is_empty() and markers_stopped, "Vorschau-Marker klingen beim Rammen sofort aus (kein Nachspawnen mehr)")

	# "Kann man danach wieder abrollen wie immer": ein voller 360°-Zyklus
	# muss die ursprüngliche Unterseite wieder freigeben, exakt wie bei
	# einer normal überrollten Schleimspur.
	var released := false
	for i in range(4):
		player.roll(Vector3.FORWARD)
		await _wait_for_input()
		if is_instance_valid(bottom_before) and not bottom_before.is_disabled():
			released = true
			break
	t.check(released, "Verklebte Seite löst sich beim erneuten Bodenkontakt wieder")

	await _reset()
	t.begin("Slime-Falle: Prognose-Feld betreten")

	player = _player()
	var slime2 : Slime = preload("res://scenes/entities/slime.tscn").instantiate()
	add_child(slime2)
	slime2.global_position = player.global_position + Vector3(5, 0, 5)
	await get_tree().process_frame
	slime2.cooldown_current = 0
	slime2.next_move = Vector3i.RIGHT

	var predicted := slime2.predict()
	if t.check(not predicted.is_empty(), "Slime hat ein vorhergesagtes Feld"):
		player.global_position = Vector3(predicted[0])
		await get_tree().process_frame
		GameManager._check_slime_traps(player)
		await get_tree().process_frame

		var top := player.get_top_face_module()
		t.check(top.is_disabled(), "Seite ist nach Betreten des Prognose-Felds verklebt")
		t.check(not is_instance_valid(slime2) or slime2.is_dead, "Slime stirbt durchs Betreten seines Prognose-Felds")


# ════════════════════════════════════════════════════════════════════
#  Fähigkeiten
# ════════════════════════════════════════════════════════════════════

func _test_turret() -> void:
	await _reset()
	t.begin("Fähigkeit: Turret")

	var player := _player()
	var dir := _open_direction()
	if t.check(dir != Vector3.ZERO, "Offene Richtung für Turret-Test vorhanden"):
		var slime : Slime = preload("res://scenes/entities/slime.tscn").instantiate()
		add_child(slime)
		slime.global_position = player.global_position + dir
		await get_tree().process_frame

		var top_slot := _top_slot(player)
		player.slot_scene(top_slot, preload("res://scenes/entities/faces/face_turret.tscn"))
		await get_tree().process_frame

		var hp_before := slime.hp
		player.get_top_face_module().activate()
		t.check(slime.hp < hp_before, "Turret fügt einem angrenzenden Gegner Schaden zu")


func _test_flamethrower() -> void:
	await _reset()
	t.begin("Fähigkeit: Flammenwerfer")

	var player := _player()
	var dir := Vector3.ZERO
	for d in [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK, Vector3.LEFT]:
		var t1 := LevelManager.world_to_grid(player.global_position + d)
		var t2 := LevelManager.world_to_grid(player.global_position + d * 2)
		if LevelManager.is_walkable(t1) and LevelManager.is_walkable(t2):
			dir = d
			break

	if t.check(dir != Vector3.ZERO, "Offene 2-Felder-Richtung für Flammenwerfer-Test vorhanden"):
		player.last_direction = dir
		var slime : Slime = preload("res://scenes/entities/slime.tscn").instantiate()
		add_child(slime)
		slime.global_position = player.global_position + dir * 2
		await get_tree().process_frame

		var top_slot := _top_slot(player)
		player.slot_scene(top_slot, preload("res://scenes/entities/faces/face_flamethrower.tscn"))
		await get_tree().process_frame

		var hp_before := slime.hp
		player.get_top_face_module().activate()
		t.check(slime.hp < hp_before, "Flammenwerfer trifft einen Gegner 2 Felder in Blickrichtung")


func _test_holo_shield() -> void:
	await _reset()
	t.begin("Fähigkeit: Holo-Schild")

	var player := _player()
	var top_slot := _top_slot(player)
	player.slot_scene(top_slot, preload("res://scenes/entities/faces/face_holo_shield.tscn"))
	await get_tree().process_frame

	player.get_top_face_module().activate()
	t.check(GameManager.player_shielded, "Schild ist nach activate() aktiv")

	var hp_before := GameManager.player_hp
	GameManager.damage_player(1)
	t.check(GameManager.player_hp == hp_before, "Schaden wird bei aktivem Schild komplett geblockt")


func _test_phase() -> void:
	await _reset()
	t.begin("Fähigkeit: Phase")

	var player := _player()
	var top_slot := _top_slot(player)
	player.slot_scene(top_slot, preload("res://scenes/entities/faces/face_phase.tscn"))
	await get_tree().process_frame

	var start_rot : Basis = player.cube.global_transform.basis
	var start_pos := player.global_position
	var dir := _open_direction()
	if t.check(dir != Vector3.ZERO, "Offene Richtung für Phase-Test vorhanden"):
		# Erwartete Zielseite: unabhängig von der Distanz dreht sich der
		# Würfel bei Phase um genau EINE Seite weiter (wie ein einzelner
		# Rollschritt, siehe Player.phase_roll()) - danach liegt also nicht
		# mehr zwangsläufig wieder Phase oben (der frühere
		# Dauer-Phase-Softlock).
		var expected_top_face := player.get_next_top_face(dir)

		player.roll(dir)
		await _wait_for_input()

		t.check(player.global_position.distance_to(start_pos) >= 1.0, "Phase bewegt den Würfel mindestens 1 Feld")
		t.check(not player.cube.global_transform.basis.is_equal_approx(start_rot), "Würfel dreht sich während Phase eine Seite weiter (löst das Dauer-Phase-Softlock)")
		t.check(player.get_top_face_module() == expected_top_face, "Nach Phase liegt genau die nächste Seite oben (eine Seite weitergedreht)")


func _test_dash() -> void:
	await _reset()
	t.begin("Fähigkeit: Dash")

	var player := _player()
	var bottom_before := player.get_bottom_face_module()
	var top_slot := _top_slot(player)
	player.slot_scene(top_slot, preload("res://scenes/entities/faces/face_dash.tscn"))
	await get_tree().process_frame

	var dir := _open_direction()
	if t.check(dir != Vector3.ZERO, "Offene Richtung für Dash-Test vorhanden"):
		var enemy_pos := player.global_position + dir
		var slime : Slime = preload("res://scenes/entities/slime.tscn").instantiate()
		add_child(slime)
		slime.global_position = enemy_pos
		await get_tree().process_frame

		# HP absichtlich unter das Maximum setzen, um den Heilungs-Effekt
		# eines "echten" Kills (über Schaden, nicht Slime-Falle) zu prüfen.
		GameManager.player_hp = GameManager.max_player_hp - 1
		var hp_before_kill := GameManager.player_hp

		var start_pos := player.global_position
		player.roll(dir)
		await _wait_for_input()

		var distance := player.global_position.distance_to(start_pos)
		t.check(distance >= 1.0, "Dash bewegt den Würfel mindestens 1 Feld")
		t.check(not is_instance_valid(slime) or slime.is_dead, "Dash-Aufprall tötet den Gegner (1 Schaden = Standard-1-HP)")
		t.check(GameManager.player_hp == hp_before_kill + 1, "Echter Kill (Dash) heilt 1 HP")


# ════════════════════════════════════════════════════════════════════
#  Gegner
# ════════════════════════════════════════════════════════════════════

func _test_sniper() -> void:
	await _reset()
	t.begin("Gegner: Scharfschütze (Reaktionszeit)")

	var player := _player()
	var sniper : Sniper = preload("res://scenes/entities/sniper.tscn").instantiate()
	add_child(sniper)
	sniper.global_position = player.global_position
	await get_tree().process_frame

	var hp_after_1 := GameManager.player_hp
	await sniper.take_turn()
	t.check(GameManager.player_hp == hp_after_1, "Kein Schaden nach 1 Zug in Reichweite")
	await sniper.take_turn()
	t.check(GameManager.player_hp == hp_after_1 - 1, "Schaden nach 2 Zügen in Folge in Reichweite")
	sniper.queue_free()

	t.begin("Gegner: Scharfschütze (Sichtlinie)")
	var origin := Vector2i.ZERO
	var blocked_tile := Vector2i.ZERO
	var found := false
	for pos in LevelManager.grid.keys():
		if found:
			break
		if not LevelManager.is_walkable(pos):
			continue
		for dx in range(-4, 5):
			for dz in range(-4, 5):
				if absi(dx) + absi(dz) > 4 or (dx == 0 and dz == 0):
					continue
				var tile : Vector2i = pos + Vector2i(dx, dz)
				if not LevelManager.is_walkable(tile):
					continue
				if not LevelManager.has_line_of_sight(pos, tile):
					origin = pos
					blocked_tile = tile
					found = true
					break
			if found:
				break

	if t.check(found, "Eine blockierte Sichtlinien-Konstellation wurde im Level gefunden"):
		var sniper2 : Sniper = preload("res://scenes/entities/sniper.tscn").instantiate()
		add_child(sniper2)
		sniper2.global_position = LevelManager.grid_to_world(origin)
		await get_tree().process_frame
		player.global_position = LevelManager.grid_to_world(blocked_tile)
		await get_tree().process_frame

		var hp_before := GameManager.player_hp
		await sniper2.take_turn()
		await sniper2.take_turn()
		t.check(GameManager.player_hp == hp_before, "Hinter einer Wand/Säule bleibt der Spieler unbeschadet")
		sniper2.queue_free()


func _test_bully_charge() -> void:
	await _reset()
	t.begin("Gegner: Bully (zweiphasiger Sturm)")

	var player := _player()

	# Künstlicher Korridor: w 0 0 p 0 0 b 0 w  (x=0..8, z=0)
	var z := 0
	for x in range(0, 9):
		var cell_type := GridCell.Type.WALL if (x == 0 or x == 8) else GridCell.Type.FLOOR
		LevelManager.grid[Vector2i(x, z)] = GridCell.new(cell_type)

	player.global_position = LevelManager.grid_to_world(Vector2i(3, z))

	var bully : Bully = preload("res://scenes/entities/bully.tscn").instantiate()
	add_child(bully)
	bully.global_position = LevelManager.grid_to_world(Vector2i(6, z))
	await get_tree().process_frame

	var hp_before := GameManager.player_hp
	await bully.take_turn()
	await get_tree().process_frame

	t.check_eq(LevelManager.world_to_grid(player.global_position), Vector2i(1, z), "Spieler landet exakt an der Wand")
	t.check_eq(LevelManager.world_to_grid(bully.global_position), Vector2i(2, z), "Bully bleibt direkt hinter dem Spieler stehen")
	t.check(GameManager.player_hp == hp_before, "Der Sturm verursacht keinen direkten Schaden")
	bully.queue_free()


func _test_bomb() -> void:
	await _reset()
	t.begin("Gegner: Bombe")

	var player := _player()
	var bomb : Bomb = preload("res://scenes/map_elements/bomb.tscn").instantiate()
	add_child(bomb)
	bomb.global_position = player.global_position
	await get_tree().process_frame

	t.check_eq(bomb.predict().size(), 0, "Keine Vorschau, solange die Bombe noch mehrere Runden tickt")

	await bomb.take_turn()
	t.check_eq(bomb.ticks_remaining, 2, "Erster Tick verringert den Timer")
	await bomb.take_turn()
	t.check_eq(bomb.ticks_remaining, 1, "Zweiter Tick verringert den Timer weiter")
	t.check_eq(bomb.predict().size(), 9, "Vorschau zeigt das 3x3-Raster kurz vor der Explosion")

	var hp_before := GameManager.player_hp
	var hp_direct_before := bomb.hp
	bomb.take_damage(999)
	t.check_eq(bomb.hp, hp_direct_before, "Bombe ist gegen direkten Schaden immun")

	await bomb.take_turn()
	t.check(GameManager.player_hp < hp_before, "Explosion fügt dem Spieler im Raster Schaden zu")
	await get_tree().process_frame  # queue_free() wirkt erst am Frame-Ende
	t.check(not is_instance_valid(bomb), "Bombe entfernt sich selbst nach der Explosion")


# ════════════════════════════════════════════════════════════════════
#  Regressionstests für zuvor gefundene Bugs
# ════════════════════════════════════════════════════════════════════

## Regression: enemy.die() während der Enemy-Turn-Schleife (z.B. eine
## explodierende Bombe) darf nachfolgende Gegner im Array nicht
## überspringen (siehe Kommentar in game_manager.gd::_begin_enemy_turn()).
func _test_enemy_turn_no_skip_on_mid_loop_death() -> void:
	await _reset()
	t.begin("Regression: Kein übersprungener Zug bei Tod während der Enemy-Turn-Schleife")

	var player := _player()
	_clear_enemies()
	await get_tree().process_frame

	var c_pos := player.global_position + Vector3(-10, 0, -10)
	var c_target := c_pos + Vector3(1, 0, 0)
	LevelManager.grid[LevelManager.world_to_grid(c_pos)] = GridCell.new(GridCell.Type.FLOOR)
	LevelManager.grid[LevelManager.world_to_grid(c_target)] = GridCell.new(GridCell.Type.FLOOR)

	var bomb : Bomb = preload("res://scenes/map_elements/bomb.tscn").instantiate()
	add_child(bomb)
	bomb.global_position = player.global_position + Vector3(10, 0, 10)
	bomb.ticks_remaining = 1  # explodiert in ihrem eigenen, nächsten Zug

	var enemy_c : Slime = preload("res://scenes/entities/slime.tscn").instantiate()
	add_child(enemy_c)
	enemy_c.global_position = c_pos
	await get_tree().process_frame
	enemy_c.next_move = Vector3i.RIGHT
	enemy_c.cooldown_current = 0

	var c_pos_before := enemy_c.global_position
	await GameManager._begin_enemy_turn()

	t.check(enemy_c.global_position != c_pos_before, "Gegner nach einem sich selbst entfernenden Gegner zieht trotzdem")


## Regression: Levelwechsel muss Prognose-Marker und lose Entities (z.B.
## Schleimspuren) aus der vorherigen Etage entfernen.
func _test_level_regenerate_cleanup() -> void:
	await _reset()
	t.begin("Regression: Aufräumen beim Levelwechsel")

	var player := _player()
	var trace : Node3D = preload("res://scenes/map_elements/slime_trace.tscn").instantiate()
	add_child(trace)
	trace.global_position = player.global_position + Vector3(2, 0, 0)

	var slime : Slime = preload("res://scenes/entities/slime.tscn").instantiate()
	add_child(slime)
	slime.global_position = player.global_position + Vector3(3, 0, 0)
	await get_tree().process_frame
	slime.next_move = Vector3i.RIGHT
	slime.show_prediction()
	await get_tree().process_frame

	LevelManager.generate_level(2, main.level_parent)
	await get_tree().process_frame

	var danger_tiles := 0
	for child in get_tree().current_scene.get_children():
		if child.name.begins_with("DangerTile"):
			danger_tiles += 1
	t.check_eq(danger_tiles, 0, "Prognose-Marker werden beim Levelwechsel entfernt")
	t.check(not is_instance_valid(trace), "Lose Schleimspur wird beim Levelwechsel entfernt")


## Regression/Sanity: Budget- und Freischaltungssystem hält sich an die
## dokumentierten Regeln (Etage 1 nur Slime, Budget = 4 + 2*Etage).
func _test_enemy_spawn_budget() -> void:
	t.begin("Gegner-Spawn-Budget")

	LevelManager.generate_level(1, main.level_parent)
	await get_tree().process_frame

	var only_slimes := true
	var total_cost := 0
	for e in GameManager.enemies:
		if not is_instance_valid(e):
			continue
		if not (e is Slime):
			only_slimes = false
		total_cost += e.spawn_cost

	t.check(only_slimes, "Auf Etage 1 sind ausschließlich Slimes freigeschaltet")
	t.check(total_cost <= 4 + 2 * 1, "Gesamtkosten überschreiten das Budget für Etage 1 nicht")


## Kein echter Netzwerktest (bräuchte ein zweites Gerät/eine zweite
## Godot-Instanz im selben WLAN) - reiner Strukturschutz gegen
## Cleanup-Regressionen: stop() muss die Rolle zurücksetzen UND den
## TCP-Server/-Port wieder vollständig freigeben, sonst würde ein zweiter
## start_hosting()-Aufruf (z.B. nach "Abbrechen" -> erneut "Hosten") am
## bereits belegten Port scheitern.
func _test_network_manager_cleanup() -> void:
	t.begin("NetworkManager: Cleanup nach stop()")

	NetworkManager.start_hosting("Testhost")
	await get_tree().process_frame
	t.check(NetworkManager.is_networked(), "start_hosting() setzt is_networked() auf true")

	NetworkManager.stop()
	t.check(not NetworkManager.is_networked(), "stop() setzt is_networked() auf false")
	t.check(NetworkManager.role == NetworkManager.Role.NONE, "stop() setzt role auf NONE zurück")

	# Regression: ein erneutes start_hosting() direkt danach darf nicht am
	# noch belegten Port scheitern (siehe Kommentar oben).
	NetworkManager.start_hosting("Testhost")
	await get_tree().process_frame
	t.check(NetworkManager.is_networked(), "Erneutes start_hosting() nach stop() gelingt (Port wieder frei)")

	NetworkManager.stop()


## Reiner Daten-Roundtrip (kein echter Netzwerktransfer nötig, siehe
## NetworkManager-Test oben - der TCP-Transport selbst ist dort bereits
## erwiesen): generiert eine Etage, serialisiert sie, wendet das Ergebnis
## erneut über apply_remote_level() an (wie es der Secondary vom Host
## empfangen würde) und prüft, dass exakt dieselbe Etage dabei herauskommt -
## Regressionsschutz gegen RNG-Divergenz zwischen Host und Secondary.
func _test_level_serialization_roundtrip() -> void:
	t.begin("Level-Sync: Serialisierung/Deserialisierung")

	LevelManager.generate_level(3, main.level_parent)
	await get_tree().process_frame

	var original_cells := {}
	for pos in LevelManager.grid.keys():
		original_cells[pos] = LevelManager.grid[pos].type
	var original_secondary_start := LevelManager.secondary_start_position
	var original_exit_2 := LevelManager.exit_position_2
	var original_enemy_count := GameManager.enemies.size()

	var data := LevelManager.serialize_level()

	LevelManager.apply_remote_level(data, main.level_parent)
	await get_tree().process_frame

	t.check_eq(LevelManager.grid.size(), original_cells.size(), "Grid-Größe bleibt nach Roundtrip gleich")

	var cells_match := true
	for pos in original_cells:
		if not LevelManager.grid.has(pos) or LevelManager.grid[pos].type != original_cells[pos]:
			cells_match = false
			break
	t.check(cells_match, "Alle Zellentypen stimmen nach Roundtrip überein")

	t.check_eq(LevelManager.secondary_start_position, original_secondary_start, "Zweiter Spawn bleibt nach Roundtrip erhalten")
	t.check_eq(LevelManager.exit_position_2, original_exit_2, "Zweites Ziel-Feld bleibt nach Roundtrip erhalten")
	t.check_eq(GameManager.enemies.size(), original_enemy_count, "Gleiche Anzahl Gegner nach Roundtrip")

	t.check(LevelManager.start_position != LevelManager.secondary_start_position, "Host- und Secondary-Spawn sind unterschiedliche Felder")
	t.check(LevelManager.exit_position != LevelManager.exit_position_2, "Die beiden Ziel-Felder sind unterschiedliche Felder")
