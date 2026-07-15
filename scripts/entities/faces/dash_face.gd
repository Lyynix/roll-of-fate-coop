class_name DashFace
extends BaseFace

const STEPS := 2

## Prüft wie viele der bis zu STEPS Felder frei sind und übergibt die
## eigentliche Bewegung (inkl. Gegner-Knockback) an Player.dash().
func modify_roll(player: Player, direction: Vector3) -> bool:
	var dir := Vector3i(direction.normalized())
	var probe := Vector3i(player.global_position)
	var steps_possible := 0

	# Koop: die andere Spieler-Kugel stoppt den Dash wie eine Wand, statt
	# hindurchzurutschen. Bleibt im Singleplayer wirkungslos.
	var other_player := GameManager.remote_player if player == GameManager.player else GameManager.player

	for i in range(STEPS):
		var candidate := probe + dir
		if not LevelManager.is_walkable(Vector2i(candidate.x, candidate.z)):
			break
		if other_player != null and Vector3i(other_player.global_position) == candidate:
			break
		probe = candidate
		steps_possible += 1

	# false statt true: roll() fällt dadurch auf seine eigene Validierung
	# zurück, die das direkt angrenzende (ebenfalls blockierte) Feld erkennt
	# und den Zug korrekt als nicht verbraucht meldet (siehe Player.roll()-
	# Rückgabewert, wichtig für den Koop-Host/Secondary-Abgleich).
	if steps_possible == 0:
		return false

	player.dash(direction, steps_possible)
	return true
