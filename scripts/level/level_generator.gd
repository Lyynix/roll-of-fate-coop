class_name LevelGenerator
extends Node
## Baut eine Etage additiv auf: ein großer, länglicher Startraum, daran über
## kurze Korridore angehängte kleinere Räume, optionale Extra-Verbindungen
## (Schleifen), eine optionale Sackgasse (reserviert für ein Würfelseiten-
## Pickup), dann Wand-/Säulen-Füllung und zuletzt die Start-/Ziel-Wahl.

const NORMAL_ROOM_MIN := 4
const NORMAL_ROOM_MAX := 7
const BIG_ROOM_SHORT_MIN := 5
const BIG_ROOM_SHORT_MAX := 8
const BIG_ROOM_LONG_MIN := 8
const BIG_ROOM_LONG_MAX := 14
const ROOM_COUNT_MIN := 4
const ROOM_COUNT_MAX := 6
const ROOM_GAP := 1                 # Mindestabstand zu fremden Räumen, damit dazwischen Wände entstehen
const CORRIDOR_LENGTH := 1
const EXTRA_CONNECTION_CHANCE := 0.5  # Chance pro zusätzlich möglicher Verbindung -> Schleifen/Alternativwege
const DEAD_END_CHANCE := 0.4
const DEAD_END_ROOM_MIN := 2
const DEAD_END_ROOM_MAX := 3
const PILLAR_CHECK_RADIUS := 3
const MAX_PLACEMENT_ATTEMPTS := 200
const OUTSIDE_WALL_MARGIN := 10  # wie weit über die Räume hinaus alles zur Wand wird

const DIRECTIONS: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]

## Mittelpunkte aller in der letzten generate()-Generierung erzeugten Sackgassen.
## Spätere Systeme (z.B. Würfelseiten-Spawner) können diese Liste auslesen.
var dead_end_centers: Array[Vector2i] = []

## Start- und Ziel-Zelle der letzten Generierung.
var start_position: Vector2i
var exit_position: Vector2i

## Zweiter Spawn im selben Raum wie start_position - fest dem Secondary-Spieler
## zugeordnet (Koop). Zweites Ziel im selben Raum wie exit_position - bewusst
## NICHT zugeordnet, beide Ziel-Felder sind gleichwertig/austauschbar.
var secondary_start_position: Vector2i
var exit_position_2: Vector2i

## Alle Raum-Rechtecke der letzten Generierung (inkl. Sackgasse).
## Spätere Systeme (z.B. Entity-Spawner) können diese Liste auslesen.
var rooms: Array[Rect2i] = []


## Erzeugt ein neues Raster für die angegebene Etage. coop steuert, ob der
## zweite Spawn/das zweite Ziel überhaupt als begehbares START/EXIT-Feld
## markiert wird - im Singleplayer gibt es nur einen Spieler, ein zweites
## sichtbares Pärchen Start-/Ziel-Tiles wäre dort nur verwirrend.
## Gibt ein Dictionary Vector2i -> GridCell zurück.
func generate(_floor_number: int, coop: bool = false) -> Dictionary:
	var grid: Dictionary = {}
	rooms = []
	dead_end_centers.clear()

	var connected_pairs: Dictionary = _generate_rooms(rooms, grid)
	_add_extra_connections(rooms, grid, connected_pairs)
	# Auf den ersten beiden Etagen ist eine Würfelseite garantiert erreichbar
	# (Sackgasse also erzwungen statt dem Zufall überlassen) - sonst könnten
	# neue Spieler bei Pech mehrere Etagen lang komplett ohne Fähigkeit
	# unterwegs sein, bevor überhaupt eine Sackgasse (und damit ein Pickup)
	# gewürfelt wird.
	_add_dead_end(rooms, grid, _floor_number <= 2)
	_generate_walls(grid)
	_fill_outside_with_walls(grid, rooms)
	_generate_pillars(grid)
	_place_pickups(grid)
	_place_start_and_exit(grid, coop)

	return grid


## Füllt alles außerhalb der Räume (innerhalb eines Randes) mit Wänden auf,
## damit klar erkennbar ist, wo die Räume enden und die Karte aufhört.
func _fill_outside_with_walls(grid: Dictionary, rooms: Array[Rect2i]) -> void:
	var bounds := rooms[0]
	for i in range(1, rooms.size()):
		bounds = bounds.merge(rooms[i])
	bounds = bounds.grow(OUTSIDE_WALL_MARGIN)

	for x in range(bounds.position.x, bounds.position.x + bounds.size.x):
		for z in range(bounds.position.y, bounds.position.y + bounds.size.y):
			var pos := Vector2i(x, z)
			if not grid.has(pos):
				grid[pos] = GridCell.new(GridCell.Type.WALL)


## Markiert die Mittelpunkte aller Sackgassen als Würfelseiten-Pickup.
func _place_pickups(grid: Dictionary) -> void:
	for pos in dead_end_centers:
		grid[pos] = GridCell.new(GridCell.Type.PICKUP)


## Bestimmt Start und Ziel als die zwei am weitesten voneinander entfernten
## Boden-Felder (Double-Sweep-Näherung über die Manhattan-Distanz), plus je ein
## zweites Feld im selben Raum für Koop (siehe secondary_start_position/exit_position_2).
func _place_start_and_exit(grid: Dictionary, coop: bool) -> void:
	var floor_cells: Array[Vector2i] = []
	for pos in grid.keys():
		if grid[pos].type == GridCell.Type.FLOOR:
			floor_cells.append(pos)

	var a: Vector2i = floor_cells[0]
	var b := _farthest_from(a, floor_cells)
	var c := _farthest_from(b, floor_cells)

	start_position = b
	exit_position = c
	secondary_start_position = _pick_secondary_point(start_position, floor_cells)
	exit_position_2 = _pick_secondary_point(exit_position, floor_cells)

	grid[start_position] = GridCell.new(GridCell.Type.START)
	grid[exit_position] = GridCell.new(GridCell.Type.EXIT)

	# secondary_start_position/exit_position_2 bleiben auch im Singleplayer
	# gültig berechnet (kein Sonderfall nötig), werden dort aber bewusst NICHT
	# als START/EXIT markiert - sonst stünden zwei sichtbare, aber nur im
	# Koop tatsächlich genutzte Start-/Ziel-Tiles verwirrend auf der Karte.
	if coop:
		grid[secondary_start_position] = GridCell.new(GridCell.Type.START)
		grid[exit_position_2] = GridCell.new(GridCell.Type.EXIT)


func _room_containing(pos: Vector2i) -> Variant:
	for room in rooms:
		if room.has_point(pos):
			return room
	return null


## Sucht ein von primary verschiedenes Boden-Feld im selben Raum wie primary -
## Grundlage für den zweiten Spawn/das zweite Ziel im Koop. Fällt (sehr
## unwahrscheinlich, kleinste Räume sind mind. 2x2) kein zweites Feld an, wird
## defensiv auf primary selbst zurückgefallen statt zu crashen.
func _pick_secondary_point(primary: Vector2i, floor_cells: Array[Vector2i]) -> Vector2i:
	var room: Variant = _room_containing(primary)
	if room == null:
		return primary

	var candidates: Array[Vector2i] = []
	for pos in floor_cells:
		if pos != primary and room.has_point(pos):
			candidates.append(pos)

	return candidates.pick_random() if not candidates.is_empty() else primary


func _farthest_from(origin: Vector2i, cells: Array[Vector2i]) -> Vector2i:
	var farthest := origin
	var farthest_dist := -1
	for cell in cells:
		var dist := absi(cell.x - origin.x) + absi(cell.y - origin.y)
		if dist > farthest_dist:
			farthest_dist = dist
			farthest = cell
	return farthest


# ── 1. Layout-Generierung & Engpässe ──

## Setzt additiv Rechtecke aneinander: ein großer, länglicher Raum als
## Ausgangspunkt, an den die übrigen, kleineren Räume angehängt und über
## kurze 1x1-Korridore (Engpässe) verbunden werden.
## Gibt zurück, welche Raum-Indexpaare dabei direkt verbunden wurden.
func _generate_rooms(rooms: Array[Rect2i], grid: Dictionary) -> Dictionary:
	var connected_pairs: Dictionary = {}

	var big_size := Vector2i(
		randi_range(BIG_ROOM_LONG_MIN, BIG_ROOM_LONG_MAX),
		randi_range(BIG_ROOM_SHORT_MIN, BIG_ROOM_SHORT_MAX)
	)
	if randf() < 0.5:
		big_size = Vector2i(big_size.y, big_size.x)

	var big_rect := Rect2i(Vector2i(-big_size.x / 2, -big_size.y / 2), big_size)
	rooms.append(big_rect)
	_carve_rect(big_rect, grid)

	var room_count := randi_range(ROOM_COUNT_MIN, ROOM_COUNT_MAX)
	var attempts := 0
	while rooms.size() < room_count and attempts < MAX_PLACEMENT_ATTEMPTS:
		attempts += 1

		var anchor_index := randi() % rooms.size()
		var anchor: Rect2i = rooms[anchor_index]
		var new_size := Vector2i(
			randi_range(NORMAL_ROOM_MIN, NORMAL_ROOM_MAX),
			randi_range(NORMAL_ROOM_MIN, NORMAL_ROOM_MAX)
		)
		var direction: Vector2i = DIRECTIONS[randi() % DIRECTIONS.size()]

		var placement := _place_adjacent_room(anchor, new_size, CORRIDOR_LENGTH, direction)
		var new_rect: Rect2i = placement.rect

		if _overlaps_existing(new_rect, rooms):
			continue

		rooms.append(new_rect)
		_carve_rect(new_rect, grid)
		for cell in placement.corridor:
			grid[cell] = GridCell.new(GridCell.Type.FLOOR)

		connected_pairs[_pair_key(anchor_index, rooms.size() - 1)] = true

	return connected_pairs


func _pair_key(i: int, j: int) -> Vector2i:
	return Vector2i(mini(i, j), maxi(i, j))


## Sucht nach Raumpaaren, die rein geometrisch direkt nebeneinander liegen
## (1 Feld Abstand, überlappende Achse), aber noch nicht verbunden sind,
## und verbindet sie mit einer gewissen Wahrscheinlichkeit zusätzlich.
## Dadurch entstehen gelegentlich Schleifen mit mehr als einem Laufweg.
func _add_extra_connections(rooms: Array[Rect2i], grid: Dictionary, connected_pairs: Dictionary) -> void:
	for i in range(rooms.size()):
		for j in range(i + 1, rooms.size()):
			if connected_pairs.has(_pair_key(i, j)):
				continue

			var link := _find_direct_link(rooms[i], rooms[j])
			if link.is_empty():
				continue

			if randf() > EXTRA_CONNECTION_CHANCE:
				continue

			grid[link.cell] = GridCell.new(GridCell.Type.FLOOR)
			connected_pairs[_pair_key(i, j)] = true


## Prüft ob zwei bereits platzierte Räume exakt 1 Feld Abstand mit
## überlappender Querachse haben, und liefert ggf. die verbindende Zelle.
func _find_direct_link(a: Rect2i, b: Rect2i) -> Dictionary:
	var left := a
	var right := b
	if b.position.x < a.position.x:
		left = b
		right = a
	if right.position.x == left.position.x + left.size.x + CORRIDOR_LENGTH:
		var overlap_start := maxi(left.position.y, right.position.y)
		var overlap_end := mini(left.position.y + left.size.y, right.position.y + right.size.y)
		if overlap_start < overlap_end:
			return {"cell": Vector2i(left.position.x + left.size.x, randi_range(overlap_start, overlap_end - 1))}

	var top := a
	var bottom := b
	if b.position.y < a.position.y:
		top = b
		bottom = a
	if bottom.position.y == top.position.y + top.size.y + CORRIDOR_LENGTH:
		var overlap_start_x := maxi(top.position.x, bottom.position.x)
		var overlap_end_x := mini(top.position.x + top.size.x, bottom.position.x + bottom.size.x)
		if overlap_start_x < overlap_end_x:
			return {"cell": Vector2i(randi_range(overlap_start_x, overlap_end_x - 1), top.position.y + top.size.y)}

	return {}


## Hängt mit DEAD_END_CHANCE (oder garantiert, wenn force) eine kleine, nur
## einfach angebundene Sackgasse an einen zufälligen Raum an - jede Sackgasse
## trägt genau ein Würfelseiten-Pickup (siehe _place_pickups()). Position
## wird in dead_end_centers vermerkt.
func _add_dead_end(rooms: Array[Rect2i], grid: Dictionary, force: bool = false) -> void:
	if not force and randf() > DEAD_END_CHANCE:
		return

	var attempts := 0
	while attempts < MAX_PLACEMENT_ATTEMPTS:
		attempts += 1

		var anchor: Rect2i = rooms[randi() % rooms.size()]
		var new_size := Vector2i(
			randi_range(DEAD_END_ROOM_MIN, DEAD_END_ROOM_MAX),
			randi_range(DEAD_END_ROOM_MIN, DEAD_END_ROOM_MAX)
		)
		var direction: Vector2i = DIRECTIONS[randi() % DIRECTIONS.size()]

		var placement := _place_adjacent_room(anchor, new_size, CORRIDOR_LENGTH, direction)
		var new_rect: Rect2i = placement.rect

		if _overlaps_existing(new_rect, rooms):
			continue

		rooms.append(new_rect)
		_carve_rect(new_rect, grid)
		for cell in placement.corridor:
			grid[cell] = GridCell.new(GridCell.Type.FLOOR)

		dead_end_centers.append(new_rect.position + new_rect.size / 2)
		return


## Platziert ein neues Rechteck der Größe new_size, das von anchor aus in
## Richtung direction um corridor_length Felder versetzt ist, und liefert
## den dazwischenliegenden geraden Korridor mit.
func _place_adjacent_room(anchor: Rect2i, new_size: Vector2i, corridor_length: int, direction: Vector2i) -> Dictionary:
	var new_pos: Vector2i
	var corridor: Array[Vector2i] = []

	if direction == Vector2i.RIGHT or direction == Vector2i.LEFT:
		var lateral := _pick_overlap_start(anchor.position.y, anchor.size.y, new_size.y)
		var row := _overlap_row(anchor.position.y, anchor.size.y, lateral, new_size.y)

		if direction == Vector2i.RIGHT:
			new_pos = Vector2i(anchor.position.x + anchor.size.x + corridor_length, lateral)
			for x in range(anchor.position.x + anchor.size.x, new_pos.x):
				corridor.append(Vector2i(x, row))
		else:
			new_pos = Vector2i(anchor.position.x - corridor_length - new_size.x, lateral)
			for x in range(new_pos.x + new_size.x, anchor.position.x):
				corridor.append(Vector2i(x, row))
	else:
		var lateral := _pick_overlap_start(anchor.position.x, anchor.size.x, new_size.x)
		var col := _overlap_row(anchor.position.x, anchor.size.x, lateral, new_size.x)

		if direction == Vector2i.DOWN:
			new_pos = Vector2i(lateral, anchor.position.y + anchor.size.y + corridor_length)
			for z in range(anchor.position.y + anchor.size.y, new_pos.y):
				corridor.append(Vector2i(col, z))
		else:
			new_pos = Vector2i(lateral, anchor.position.y - corridor_length - new_size.y)
			for z in range(new_pos.y + new_size.y, anchor.position.y):
				corridor.append(Vector2i(col, z))

	return {"rect": Rect2i(new_pos, new_size), "corridor": corridor}


## Wählt einen Startwert für die neue Raum-Achse, sodass sie sich mit der
## Anker-Achse um mindestens 1 Feld überlappt (für einen geraden Korridor).
func _pick_overlap_start(anchor_start: int, anchor_len: int, new_len: int) -> int:
	var min_start := anchor_start - new_len + 1
	var max_start := anchor_start + anchor_len - 1
	return randi_range(min_start, max_start)


## Gibt eine zufällige Koordinate innerhalb der Überlappung beider Achsen zurück.
func _overlap_row(anchor_start: int, anchor_len: int, new_start: int, new_len: int) -> int:
	var overlap_start := maxi(anchor_start, new_start)
	var overlap_end := mini(anchor_start + anchor_len, new_start + new_len)
	return randi_range(overlap_start, overlap_end - 1)


func _overlaps_existing(rect: Rect2i, rooms: Array[Rect2i]) -> bool:
	var expanded := rect.grow(ROOM_GAP)
	for other in rooms:
		if expanded.intersects(other):
			return true
	return false


func _carve_rect(rect: Rect2i, grid: Dictionary) -> void:
	for x in range(rect.position.x, rect.position.x + rect.size.x):
		for z in range(rect.position.y, rect.position.y + rect.size.y):
			grid[Vector2i(x, z)] = GridCell.new(GridCell.Type.FLOOR)


# ── 2. Wand-Umrandung ──

## Jedes Feld, das an ein Boden-Feld grenzt (8 Nachbarn) und noch keine
## Zuweisung besitzt, wird zur Wand.
func _generate_walls(grid: Dictionary) -> void:
	var floor_cells := grid.keys()
	var new_walls: Dictionary = {}

	for cell in floor_cells:
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var neighbor: Vector2i = cell + Vector2i(dx, dz)
				if not grid.has(neighbor) and not new_walls.has(neighbor):
					new_walls[neighbor] = GridCell.new(GridCell.Type.WALL)

	for pos in new_walls:
		grid[pos] = new_walls[pos]


# ── 3. Säulen-Platzierung ──

## Boden-Felder, die im Umkreis von PILLAR_CHECK_RADIUS (Manhattan-Distanz)
## kein Hindernis (Wand oder Säule) haben, werden selbst zur Säule.
func _generate_pillars(grid: Dictionary) -> void:
	var floor_cells: Array[Vector2i] = []
	for pos in grid.keys():
		if grid[pos].type == GridCell.Type.FLOOR:
			floor_cells.append(pos)

	for pos in floor_cells:
		if _has_obstacle_within(grid, pos, PILLAR_CHECK_RADIUS):
			continue
		grid[pos] = GridCell.new(GridCell.Type.PILLAR)


func _has_obstacle_within(grid: Dictionary, pos: Vector2i, radius: int) -> bool:
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if dx == 0 and dz == 0:
				continue
			if absi(dx) + absi(dz) > radius:
				continue
			var neighbor := pos + Vector2i(dx, dz)
			if not grid.has(neighbor):
				continue
			var type: GridCell.Type = grid[neighbor].type
			if type == GridCell.Type.WALL or type == GridCell.Type.PILLAR:
				return true
	return false
