class_name FlamethrowerFace
extends BaseFace

const DAMAGE := 1
const RANGE := 2
const FLAME_BURST_SCENE: PackedScene = preload("res://scenes/map_elements/flame_burst.tscn")

@onready var emit_point: Node3D = $EmitPoint

func activate() -> void:
	super.activate()
	_fire()

## Schaden auf den RANGE Feldern direkt vor dem Würfel in der aktuellen
## Blickrichtung (letzte Bewegungsrichtung). Statt mehrerer fixer EmitPoints
## wird die gesamte Seite so gedreht, dass ihre lokale +X-Achse (Kopf/Düse
## des Modells) in Schussrichtung zeigt - der einzige EmitPoint (fix bei
## lokal +X, siehe Szene) landet dadurch automatisch an der richtigen
## Welt-Position/-Richtung.
##
## WICHTIG: global_transform setzen, nicht basis/transform! dir ist eine
## Welt-Richtung, aber basis/transform sind relativ zum Slot-Marker dieser
## Seite - der je nach aktueller Würfel-Rotation selbst beliebig verdreht
## ist. "basis = ..." vermischt die Ziel-Richtung also mit der zufälligen
## Würfel-Rotation und stimmt nur, wenn der Würfel gerade zufällig in
## Ausgangs-Orientierung liegt (das sah beim Testen aus wie "Modell falsch
## rum gebaut", war aber genau dieser Bug). global_transform kompensiert das
## automatisch, unabhängig davon wie der Würfel gerade orientiert ist.
## Sound + Partikel nur bei tatsächlichem Treffer, sonst würde bei jeder
## Aktivierung (auch ohne Gegner im Bereich) unnötig oft das Feuer-Geräusch
## kommen.
func _fire() -> void:
	var player := owner_player as Player
	var origin := Vector3i(player.global_position)
	var dir := Vector3i(player.last_direction.normalized())

	var hit_enemies: Array[BaseEnemy] = []
	for i in range(1, RANGE + 1):
		var enemy := GameManager.get_enemy_at(origin + dir * i)
		if enemy != null:
			hit_enemies.append(enemy)

	if hit_enemies.is_empty():
		return

	SoundManager.play_sfx("flame")
	global_transform = Transform3D(_basis_with_x(Vector3(dir)), global_position)
	_spawn_flame_burst(Vector3(dir))

	for enemy in hit_enemies:
		enemy.take_damage(DAMAGE)


## Baut eine Basis, deren lokale +X-Achse exakt auf dir zeigt (Y/Z beliebig,
## solange orthonormal - das Modell ist um seine eigene Achse nicht
## richtungsabhängig).
static func _basis_with_x(dir: Vector3) -> Basis:
	var x := dir.normalized()
	var z := x.cross(Vector3.UP).normalized()
	var y := z.cross(x)
	return Basis(x, y, z)


func _spawn_flame_burst(dir: Vector3) -> void:
	var burst := FLAME_BURST_SCENE.instantiate()
	var player := owner_player
	player.get_tree().current_scene.add_child(burst)
	burst.global_position = emit_point.global_position
	burst.configure(dir, RANGE)
