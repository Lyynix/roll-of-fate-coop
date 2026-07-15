class_name FacePickup
extends BaseEntity

## Welche Würfelseite hier liegt und beim Überrollen angebracht wird. Der
## Setter aktualisiert sofort die im Slot angezeigte Face-Szene - auch wenn
## er erst nach dem Instanziieren gesetzt wird (LevelManager setzt
## ability_scene mal vor, mal nach add_child(), siehe _spawn_tiles() vs.
## spawn_face_pickup()), daher zusätzlich der Aufruf in _on_ready().
@export var ability_scene: PackedScene:
	set(value):
		ability_scene = value
		_update_visual()

@onready var slot: Marker3D = $Slot

var _visual_instance: Node3D = null


func _on_ready() -> void:
	_update_visual()


## Tauscht die aktuell im Slot angezeigte Seite gegen ability_scene aus, so
## dass auf dem Pad immer optisch genau die Seite liegt, die man beim
## Überrollen auch tatsächlich bekommt.
func _update_visual() -> void:
	if slot == null or ability_scene == null:
		return

	if _visual_instance != null:
		_visual_instance.queue_free()

	_visual_instance = ability_scene.instantiate()
	slot.add_child(_visual_instance)


func on_player_entered(entered_player: Node3D) -> void:
	SoundManager.play_sfx("pick_up_face")
	var player := entered_player as Player
	var displaced_scene := player.attach_to_bottom(ability_scene)

	if displaced_scene != null:
		LevelManager.spawn_face_pickup(displaced_scene, global_position)

	remove()
