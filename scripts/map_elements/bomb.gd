class_name Bomb
extends BaseEnemy

const DAMAGE := 2
const FUSE_TURNS := 3

var ticks_remaining := FUSE_TURNS


## Bomben sind unverwundbar - eingehender Schaden wird komplett ignoriert,
## sie verschwinden ausschließlich über ihre eigene Explosion.
func take_damage(_amount: int) -> void:
	pass


func _execute_turn() -> void:
	ticks_remaining -= 1
	if ticks_remaining <= 0:
		_explode()


## Massiver Schaden an Spieler und anderen Gegnern im 3x3-Raster.
func _explode() -> void:
	print("[", name, "] BOOM!")
	SoundManager.play_sfx("explosion")
	var origin := Vector3i(global_position)

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var pos := origin + Vector3i(dx, 0, dz)

			for p in GameManager.get_players():
				if Vector3i(p.global_position) == pos:
					GameManager.damage_player(DAMAGE)

			var enemy := GameManager.get_enemy_at(pos)
			if enemy != null and enemy != self:
				enemy.take_damage(DAMAGE)

	GameManager.unregister_enemy(self)
	queue_free()


## Zeigt das Explosionsraster, sobald die Bombe im nächsten Zug hochgeht.
func predict() -> Array[Vector3i]:
	if ticks_remaining > 1:
		return []

	var origin := Vector3i(global_position)
	var tiles: Array[Vector3i] = []
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			tiles.append(origin + Vector3i(dx, 0, dz))
	return tiles


## Statt jedes Feld einzeln zu markieren (Basisklasse): nur der Umriss des
## 3x3-Explosionsrasters, siehe BaseEnemy._spawn_outline_particles().
func show_prediction() -> void:
	hide_prediction()
	_spawn_outline_particles(predict())
