extends Node
## Verwaltet das statische Spielfeld-Raster (Vector2i -> GridCell) samt
## Wand-/Tile-/Entity-Spawning pro Etage und stellt die geteilten
## Geometrie-Abfragen bereit: Grid<->Welt-Umrechnung, Begehbarkeit,
## Sichtlinie (Bresenham) und "weitestes begehbares Feld in einer Richtung".

var grid: Dictionary = {}   # Vector2i -> GridCell
var grid_size: float = 1.0
const WALL_HEIGHT := 0.5  # niedriger als grid_size, damit man über Wände hinwegsehen kann

## Leichte Höhenvariation der Wände/Säulen über Perlin-Noise statt einer
## fixen Höhe, rein für etwas visuelle Struktur - beeinflusst nicht die
## Begehbarkeit (is_walkable() prüft weiterhin nur den Zelltyp).
const WALL_HEIGHT_MIN := 0.2
const WALL_HEIGHT_MAX := 0.7
const NOISE_SCALE := 2.0
var _wall_height_noise := FastNoiseLite.new()

## Wellen-Effekt: nach jeder Spielerbewegung läuft ein Höhen-Ausschlag vom
## Zielfeld aus als expandierender Ring durch alle Wand-/Säulen-Instanzen
## (siehe trigger_wave()/_update_wall_heights()) - rein visuell, ändert
## nichts an is_walkable().
const WAVE_SPEED := 8.0        # Felder pro Sekunde, wie schnell der Ring nach außen läuft
const WAVE_AMPLITUDE := 0.35
const WAVE_WIDTH := 1.5        # Breite des Ausschlag-Rings in Feldern
const WAVE_DURATION := 2.0     # Sekunden bis eine einzelne Welle komplett abklingt

## Schadens-Noise: zusätzliche, zeitlich wandernde Höhen-Störung (Zittern) auf
## allen Wänden/Säulen, solange der Spieler nicht auf vollen HP ist (siehe
## _on_player_hp_changed()). DAMAGE_NOISE_FREQUENCY bestimmt zusammen mit
## DAMAGE_NOISE_SPEED, wie schnell sich der Noise-Wert an einer festen
## Position zeitlich ändert (ein voller Auf-Ab-Zyklus dauert ungefähr
## 1 / (frequency * speed) Sekunden) - mit FastNoiseLites Standard-Frequenz
## (0.01) bräuchte das hier über 60 Sekunden und wirkte dadurch eingefroren.
const DAMAGE_NOISE_FREQUENCY := 1.0
const DAMAGE_NOISE_AMPLITUDE := 0.25
const DAMAGE_NOISE_SPEED := 8.0
var _damage_noise := FastNoiseLite.new()
var _damage_active: bool = false

## Parallele Arrays (Index i = dieselbe Wand-Instanz wie in
## _wall_multimesh.multimesh) - getrennt von der Multimesh-Transform
## gehalten, da _update_wall_heights() jeden Frame neu aus Basis-Höhe +
## Wellen-/Noise-Offset rechnet, statt die bereits verzerrte Transform
## weiterzuverformen.
var _wall_positions: Array[Vector2i] = []
var _wall_base_heights: Array[float] = []

var _elapsed_time: float = 0.0
## Mehrere Wellen können gleichzeitig laufen - eine neue Bewegung während
## einer noch laufenden Welle unterbricht diese nicht, sondern startet eine
## zusätzliche (siehe trigger_wave()). Jeder Eintrag: {"origin": Vector3,
## "start_time": float}. Abgelaufene Wellen werden in _update_wall_heights()
## einmal pro Frame aussortiert.
var _active_waves: Array[Dictionary] = []

## Reihenfolge bestimmt auch die Freischaltung: Etage N schaltet die ersten
## N Einträge frei (Etage 1 nur Slime, Etage 2 + Sniper, usw.).
const ENEMY_SCENES: Array[PackedScene] = [
	preload("res://scenes/entities/slime.tscn"),
	preload("res://scenes/entities/sniper.tscn"),
	preload("res://scenes/entities/bully.tscn"),
	preload("res://scenes/entities/bomber.tscn"),
]
## Budget-Kosten je Gegnertyp, gleiche Reihenfolge wie ENEMY_SCENES - muss
## zum spawn_cost der jeweiligen Gegner-Szene passen (siehe BaseEnemy).
const ENEMY_COSTS: Array[int] = [3, 3, 4, 5]

const ENEMY_BUDGET_BASE := 4
const ENEMY_BUDGET_PER_FLOOR := 2

## Würfelseiten, die auf Pickup-Feldern (Sackgassen) gefunden werden können.
const ABILITY_POOL: Array[PackedScene] = [
	preload("res://scenes/entities/faces/face_turret.tscn"),
	preload("res://scenes/entities/faces/face_holo_shield.tscn"),
	preload("res://scenes/entities/faces/face_phase.tscn"),
	preload("res://scenes/entities/faces/face_dash.tscn"),
	preload("res://scenes/entities/faces/face_flamethrower.tscn"),
]

var start_position: Vector2i
var exit_position: Vector2i

## Koop: zweiter Spawn (fest dem Secondary-Spieler zugeordnet) und zweites,
## gleichwertiges/unzugeordnetes Ziel-Feld - siehe LevelGenerator.
var secondary_start_position: Vector2i
var exit_position_2: Vector2i

var _level_parent: Node3D = null
var _generator: LevelGenerator = LevelGenerator.new()
var _start_tile_scene: PackedScene = preload("res://scenes/map_elements/start_tile.tscn")
var _exit_tile_scene: PackedScene = preload("res://scenes/map_elements/exit_tile.tscn")
var _pickup_tile_scene: PackedScene = preload("res://scenes/map_elements/pickup_tile.tscn")
var _wall_multimesh: MultiMeshInstance3D = null
var _wall_count: int = 0
var _spawned_tiles: Array[Node3D] = []

## Letzte gewürfelte Pickup-/Gegner-Entscheidungen (siehe _roll_pickup_choices()/
## _roll_enemy_spawns()) - werden von serialize_level() für Koop verschickt,
## damit der Secondary dieselben Ergebnisse übernimmt statt selbst zu würfeln.
var _last_floor_number: int = 0
var _last_pickup_choices: Dictionary = {}
var _last_enemy_spawns: Array[Dictionary] = []


func _ready() -> void:
	add_child(_generator)
	_wall_height_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_wall_height_noise.frequency = 1.0 / NOISE_SCALE
	_damage_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_damage_noise.frequency = DAMAGE_NOISE_FREQUENCY

	GameManager.player_hp_changed.connect(_on_player_hp_changed)


func _on_player_hp_changed(current: int, max_hp: int) -> void:
	_damage_active = current < max_hp


## Vom GameManager verdrahtet (siehe register_player()/register_remote_player())
## - startet eine zusätzliche Wellen-Auslenkung von world_pos aus, ohne eine
## bereits laufende Welle zu unterbrechen (siehe _active_waves).
func trigger_wave(world_pos: Vector3) -> void:
	_active_waves.append({"origin": world_pos, "start_time": _elapsed_time})


func _process(delta: float) -> void:
	_elapsed_time += delta
	if not _wall_positions.is_empty():
		_update_wall_heights()


## Rechnet für jede Wand-/Säulen-Instanz die aktuelle Höhe aus Basis-Höhe +
## Wellen-Offset (Summe aller noch aktiven Wellen, die gerade durch dieses
## Feld laufen) + Schadens-Noise (falls der Spieler nicht auf vollen HP ist)
## und setzt die Multimesh-Transform neu - jeden Frame neu aus den
## Basiswerten statt kumulativ, damit sich nichts aufschaukelt.
func _update_wall_heights() -> void:
	var multimesh := _wall_multimesh.multimesh

	# Abgelaufene Wellen einmal pro Frame aussortieren, nicht pro Wand-Instanz.
	_active_waves = _active_waves.filter(
		func(wave: Dictionary) -> bool: return _elapsed_time - wave["start_time"] < WAVE_DURATION
	)

	for i in range(_wall_positions.size()):
		var pos := _wall_positions[i]
		var height := _wall_base_heights[i]
		var world_pos := grid_to_world(pos)

		for wave in _active_waves:
			var wave_age: float = _elapsed_time - wave["start_time"]
			var wave_radius := wave_age * WAVE_SPEED
			var origin: Vector3 = wave["origin"]
			var dist := Vector2(world_pos.x, world_pos.z).distance_to(Vector2(origin.x, origin.z))
			var wave_offset := dist - wave_radius
			if absf(wave_offset) < WAVE_WIDTH:
				var wave_shape := cos(wave_offset / WAVE_WIDTH * PI * 0.5)
				var wave_fade := 1.0 - (wave_age / WAVE_DURATION)
				# Minus statt Plus: die Welle drückt die Wand kurz nach unten
				# ein, statt sie zusätzlich in die Höhe schießen zu lassen.
				height -= WAVE_AMPLITUDE * wave_shape * wave_fade

		if _damage_active:
			var noise_value := _damage_noise.get_noise_3d(pos.x, pos.y, _elapsed_time * DAMAGE_NOISE_SPEED)
			height += noise_value * DAMAGE_NOISE_AMPLITUDE

		height = maxf(height, 0.05)

		var instance_origin := world_pos + Vector3(0, height / 2.0, 0)
		var basis := Basis().scaled(Vector3(1.0, height / WALL_HEIGHT, 1.0))
		multimesh.set_instance_transform(i, Transform3D(basis, instance_origin))


## Generiert eine neue Etage und instanziert die Wand- und Tile-Platzhalter unter parent.
func generate_level(floor_number: int, parent: Node3D) -> void:
	_level_parent = parent
	_clear_tiles()
	_clear_entities()

	grid = _generator.generate(floor_number, NetworkManager.is_networked())
	start_position = _generator.start_position
	exit_position = _generator.exit_position
	secondary_start_position = _generator.secondary_start_position
	exit_position_2 = _generator.exit_position_2

	_last_floor_number = floor_number
	_last_pickup_choices = _roll_pickup_choices()
	_last_enemy_spawns = _roll_enemy_spawns(floor_number)

	_spawn_walls()
	_spawn_tiles(_last_pickup_choices)
	_spawn_entities_from_data(_last_enemy_spawns)

	var pillar_count := 0
	for pos in grid.keys():
		if grid[pos].type == GridCell.Type.PILLAR:
			pillar_count += 1
	print("[LevelManager] Etage ", floor_number, " generiert: ", grid.size(), " Zellen, ", _wall_count,
		" Wände/Säulen (davon ", pillar_count, " Säulen), ", _generator.dead_end_centers.size(), " Sackgasse(n)")


## Baut eine vom Host per serialize_level() verschickte Etage 1:1 nach - ohne
## jede eigene Zufallsentscheidung (kein _generator.generate()-Aufruf), damit
## Grid/Gegner/Pickups nicht unabhängig vom Host abweichen können.
func apply_remote_level(data: Dictionary, parent: Node3D) -> void:
	_level_parent = parent
	_clear_tiles()
	_clear_entities()

	grid = {}
	var cells: Dictionary = data["cells"]
	for pos in cells:
		grid[pos] = GridCell.new(cells[pos])

	start_position = data["start_position"]
	secondary_start_position = data["secondary_start_position"]
	exit_position = data["exit_position"]
	exit_position_2 = data["exit_position_2"]

	_last_floor_number = data["floor"]
	_last_pickup_choices = data["pickups"]
	_last_enemy_spawns = data["enemies"]

	_spawn_walls()
	_spawn_tiles(_last_pickup_choices)
	_spawn_entities_from_data(_last_enemy_spawns)

	print("[LevelManager] Etage ", _last_floor_number, " vom Host übernommen: ", grid.size(), " Zellen")


## Serialisiert die aktuelle Etage als reine Daten für Koop (siehe
## NetworkManager.send()) - Gegenstück zu apply_remote_level().
func serialize_level() -> Dictionary:
	var cells := {}
	for pos in grid.keys():
		cells[pos] = grid[pos].type

	return {
		"type": "level_data",
		"floor": _last_floor_number,
		"cells": cells,
		"start_position": start_position,
		"secondary_start_position": secondary_start_position,
		"exit_position": exit_position,
		"exit_position_2": exit_position_2,
		"pickups": _last_pickup_choices,
		"enemies": _last_enemy_spawns,
	}


## Mittelpunkte aller Sackgassen der aktuellen Etage (z.B. für Würfelseiten-Pickups).
func dead_end_centers() -> Array[Vector2i]:
	return _generator.dead_end_centers


func _clear_tiles() -> void:
	for tile in _spawned_tiles:
		if not is_instance_valid(tile):
			continue
		if tile is BaseEntity:
			GameManager.unregister_entity(tile)
		tile.queue_free()
	_spawned_tiles.clear()


## Räumt nicht nur die von hier selbst gespawnten Gegner auf, sondern
## sämtliche zur Laufzeit lose entstandenen Entities (z.B. Schleimspuren,
## die ein Slime hinterlassen hat) - GameManager.enemies/entities sind die
## einzige vollständige Quelle dafür, sonst überleben solche Objekte einen
## Etagenwechsel als Geister.
func _clear_entities() -> void:
	for enemy in GameManager.enemies.duplicate():
		if is_instance_valid(enemy):
			# immediate=true: ein langsames Ausklingen in die bereits neu
			# generierte Etage hinein wäre verwirrend, hier soll sofort
			# alles weg sein (siehe BaseEnemy.hide_prediction()).
			enemy.hide_prediction(true)
			GameManager.unregister_enemy(enemy)
			enemy.queue_free()

	for entity in GameManager.entities.duplicate():
		if is_instance_valid(entity):
			GameManager.unregister_entity(entity)
			entity.queue_free()


## Rendert alle Wand-/Säulen-Zellen über ein einzelnes MultiMeshInstance3D,
## da bei großen Karten mehrere Tausend Einzel-Szenen die Performance
## einbrechen lassen würden.
func _spawn_walls() -> void:
	if _level_parent == null:
		return

	var positions: Array[Vector2i] = []
	for pos in grid.keys():
		var cell: GridCell = grid[pos]
		if cell.type == GridCell.Type.WALL or cell.type == GridCell.Type.PILLAR:
			positions.append(pos)

	_ensure_wall_multimesh()

	# Seed aus _last_floor_number statt echtem Zufall: deterministisch pro
	# Etage, damit Host und Secondary im Koop exakt dasselbe Höhenmuster
	# sehen, ohne das eigens synchronisieren zu müssen - beide haben
	# _last_floor_number zu diesem Zeitpunkt bereits identisch gesetzt
	# (siehe generate_level()/apply_remote_level(), jeweils direkt vor
	# dem _spawn_walls()-Aufruf).
	_wall_height_noise.seed = _last_floor_number

	_wall_multimesh.multimesh.instance_count = positions.size()
	_wall_positions = positions
	_wall_base_heights = []
	for pos in positions:
		_wall_base_heights.append(_wall_height_for(pos))

	# Einmaliger Ausgangszustand (Basis-Höhe, keine Welle/Noise aktiv) -
	# _process()/_update_wall_heights() übernimmt ab dem nächsten Frame.
	_update_wall_heights()

	_wall_count = positions.size()


func _wall_height_for(pos: Vector2i) -> float:
	var noise_value := _wall_height_noise.get_noise_2d(pos.x, pos.y)  # -1..1
	return remap(noise_value, -1.0, 1.0, WALL_HEIGHT_MIN, WALL_HEIGHT_MAX)


func _ensure_wall_multimesh() -> void:
	if _wall_multimesh != null and is_instance_valid(_wall_multimesh):
		if _wall_multimesh.get_parent() != _level_parent:
			_wall_multimesh.get_parent().remove_child(_wall_multimesh)
			_level_parent.add_child(_wall_multimesh)
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.4, 0.4, 0.45)

	var mesh := BoxMesh.new()
	mesh.size = Vector3(grid_size, WALL_HEIGHT, grid_size)
	mesh.material = material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh

	_wall_multimesh = MultiMeshInstance3D.new()
	_wall_multimesh.multimesh = multimesh
	_level_parent.add_child(_wall_multimesh)


## Reine Würfel-Logik für die Pickup-Fähigkeit jeder PICKUP-Zelle (ein Wurf pro
## Zelle) - liefert einen Index in ABILITY_POOL statt der Szene selbst, damit
## sich das Ergebnis unverändert für Koop verschicken lässt (siehe serialize_level()).
func _roll_pickup_choices() -> Dictionary:
	var choices := {}
	for pos in grid.keys():
		if grid[pos].type == GridCell.Type.PICKUP:
			choices[pos] = randi() % ABILITY_POOL.size()
	return choices


## pickup_choices: Vector2i -> Index in ABILITY_POOL (siehe _roll_pickup_choices()) -
## keine eigene Zufallslogik mehr, damit Host und Secondary (siehe
## apply_remote_level()) dieselben Fähigkeiten an denselben Feldern platzieren.
func _spawn_tiles(pickup_choices: Dictionary) -> void:
	if _level_parent == null:
		return

	for pos in grid.keys():
		var cell: GridCell = grid[pos]
		var scene: PackedScene = null
		match cell.type:
			GridCell.Type.START:
				scene = _start_tile_scene
			GridCell.Type.EXIT:
				scene = _exit_tile_scene
			GridCell.Type.PICKUP:
				scene = _pickup_tile_scene

		if scene == null:
			continue

		var tile := scene.instantiate()
		_level_parent.add_child(tile)
		tile.position = grid_to_world(pos)
		_spawned_tiles.append(tile)

		if tile is FacePickup:
			var ability_index: int = pickup_choices.get(pos, 0)
			tile.ability_scene = ABILITY_POOL[ability_index]


## Legt eine verdrängte Würfelseite als neues, aufsammelbares Pickup auf den
## Boden - wird von FacePickup.on_player_entered() nach attach_to_bottom()
## aufgerufen.
func spawn_face_pickup(ability_scene: PackedScene, world_pos: Vector3) -> void:
	if _level_parent == null:
		return

	var tile : FacePickup = _pickup_tile_scene.instantiate()
	tile.ability_scene = ability_scene
	_level_parent.add_child(tile)
	tile.global_position = world_pos
	_spawned_tiles.append(tile)


## Reine Würfel-Logik (Budget/Freischaltung/Position) ohne zu spawnen -
## Ergebnis wird sowohl lokal instanziert (_spawn_entities_from_data()) als
## auch für Koop verschickt (serialize_level()), damit nie zweimal unabhängig
## gewürfelt wird. Frühe Etagen schalten die Gegnertypen nacheinander frei
## (siehe ENEMY_SCENES-Reihenfolge), Gegner spawnen zufällig verteilt in
## Räumen (außer im Start-Raum), bis das mit der Etage wachsende Punktebudget
## erschöpft ist.
##
## cooldown_roll ist ein Float in [0, 1) statt eines fertigen
## cooldown_current-Werts: cooldown_max hängt vom jeweiligen Gegnertyp ab und
## ist erst nach dem Instanziieren bekannt (_on_ready() der Subklasse) - der
## Wurf selbst passiert hier trotzdem nur einmal, die Umrechnung in einen
## konkreten Cooldown erfolgt deterministisch in _spawn_entities_from_data().
func _roll_enemy_spawns(floor_number: int) -> Array[Dictionary]:
	var spawns: Array[Dictionary] = []
	if grid.is_empty():
		return spawns

	var start_room: Variant = _room_containing(start_position)

	var candidates: Array[Vector2i] = []
	for pos in grid.keys():
		if grid[pos].type != GridCell.Type.FLOOR:
			continue
		if start_room != null and start_room.has_point(pos):
			continue
		candidates.append(pos)
	candidates.shuffle()

	var unlocked_count := mini(floor_number, ENEMY_SCENES.size())
	var budget := ENEMY_BUDGET_BASE + floor_number * ENEMY_BUDGET_PER_FLOOR

	var candidate_index := 0
	while budget > 0 and candidate_index < candidates.size():
		var affordable_indices: Array[int] = []
		for i in range(unlocked_count):
			if ENEMY_COSTS[i] <= budget:
				affordable_indices.append(i)

		if affordable_indices.is_empty():
			break

		var chosen : int = affordable_indices.pick_random()
		spawns.append({
			"scene_index": chosen,
			"pos": candidates[candidate_index],
			"cooldown_roll": randf(),
		})

		budget -= ENEMY_COSTS[chosen]
		candidate_index += 1

	return spawns


## spawns: Ergebnis von _roll_enemy_spawns() - keine eigene Zufallslogik mehr,
## damit sich dasselbe Ergebnis 1:1 lokal (Host) und aus empfangenen
## Netzwerkdaten (Secondary, siehe apply_remote_level()) anwenden lässt.
func _spawn_entities_from_data(spawns: Array[Dictionary]) -> void:
	if _level_parent == null:
		return

	for spawn in spawns:
		var entity := ENEMY_SCENES[spawn["scene_index"]].instantiate()
		_level_parent.add_child(entity)
		entity.global_position = grid_to_world(spawn["pos"])

		# Zufälliger Start-Cooldown, damit nicht alle gespawnten Gegner
		# synchron im selben Zug zum ersten Mal aktiv werden - siehe
		# Kommentar zu cooldown_roll in _roll_enemy_spawns().
		if entity is BaseEnemy and entity.cooldown_max > 0:
			var roll: float = spawn["cooldown_roll"]
			entity.cooldown_current = mini(int(roll * entity.cooldown_max), entity.cooldown_max - 1)


func _room_containing(pos: Vector2i) -> Variant:
	for room in _generator.rooms:
		if room.has_point(pos):
			return room
	return null


func grid_to_world(pos: Vector2i) -> Vector3:
	return Vector3(pos.x, 0, pos.y) * grid_size


func world_to_grid(pos: Vector3) -> Vector2i:
	return Vector2i(roundi(pos.x / grid_size), roundi(pos.z / grid_size))


func get_cell(pos: Vector2i) -> GridCell:
	return grid.get(pos)


## Prüft ob ein Feld statisch begehbar ist (keine Wand/Säule, innerhalb des Rasters).
## Maßgeblich dafür, ob sich Spieler/Gegner dorthin bewegen dürfen.
func is_walkable(pos: Vector2i) -> bool:
	var cell: GridCell = grid.get(pos)
	return cell != null and cell.is_walkable()


## Geht von `from` aus geradlinig in Richtung `direction` (Y-Komponente
## wird ignoriert), bis zu `max_distance` Felder weit oder bis zum ersten
## Hindernis - je nachdem was zuerst eintritt - und gibt das letzte noch
## begehbare Feld zurück (kann `from` selbst sein, wenn das Nachbarfeld
## bereits blockiert ist). Geteilte Grundlage für alles, was sich in einer
## geraden Linie bewegt, bis es eine Wand/Säule trifft: Phase, der
## Knockback durch Dash, und der Bully-Sturm/-Schub.
func furthest_walkable(from: Vector3i, direction: Vector3i, max_distance: int = 999) -> Vector3i:
	var furthest := from
	for i in range(1, max_distance + 1):
		var candidate := from + direction * i
		if not is_walkable(Vector2i(candidate.x, candidate.z)):
			break
		furthest = candidate
	return furthest


## Prüft per Bresenham-Linie, ob zwischen from und to eine freie Schussbahn
## besteht (keine Wand/Säule auf dem Weg dazwischen). Die beiden Endpunkte
## selbst werden nicht geprüft.
func has_line_of_sight(from: Vector2i, to: Vector2i) -> bool:
	var x0 := from.x
	var y0 := from.y
	var x1 := to.x
	var y1 := to.y

	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy

	while true:
		var current := Vector2i(x0, y0)
		if current != from and current != to and not is_walkable(current):
			return false

		if x0 == x1 and y0 == y1:
			break

		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy

	return true


## Prüft ob auf einem Feld bereits eine Entity (Spieler/Gegner) steht.
func is_occupied(pos: Vector2i) -> bool:
	return GameManager.get_entity_at(Vector3i(grid_to_world(pos))) != null
