class_name PhaseFace
extends BaseFace

const MAX_DISTANCE := 3

## Gleitet durch ALLES hindurch - Wände, Säulen und Gegner blockieren den Weg
## nicht, das unterscheidet Phase bewusst von jeder anderen Bewegungsart im
## Spiel. Landet dabei aber nie IN einer Wand/Säule: von MAX_DISTANCE
## absteigend wird die größte Distanz gewählt, deren ZIELFELD begehbar ist -
## Wände auf dem Weg DAZWISCHEN spielen keine Rolle, nur die Landeposition
## muss begehbar sein. Liefert keine der drei Distanzen ein begehbares Ziel
## (nur nahe am Kartenrand realistisch), bleibt der Zug ungültig; roll()
## fällt dann auf seine normale Validierung zurück.
##
## Der Würfel dreht sich dabei trotzdem nur um genau eine Seite weiter (siehe
## Player.phase_roll()) - so liegt die Phase-Seite danach nicht mehr oben und
## man kann nie im Dauer-Phase-Zustand hängenbleiben.
func modify_roll(player: Player, direction: Vector3) -> bool:
	var dir := Vector3i(direction.normalized())
	var current := Vector3i(player.global_position)

	var steps := _furthest_walkable_landing(current, dir)
	if steps == 0:
		return false

	player.last_direction = direction
	player.phase_roll(direction, steps)
	return true


## Größte Distanz in [1, MAX_DISTANCE], deren Zielfeld begehbar ist (0, wenn
## keine davon begehbar ist) - geteilte Grundlage für die echte Bewegung
## sowie die Ghost-Planungsvorschau (siehe GhostPlayer._step_phase()).
static func _furthest_walkable_landing(current: Vector3i, dir: Vector3i) -> int:
	for candidate_steps in range(MAX_DISTANCE, 0, -1):
		var target := current + dir * candidate_steps
		if LevelManager.is_walkable(Vector2i(target.x, target.z)):
			return candidate_steps
	return 0
