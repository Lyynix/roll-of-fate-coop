@tool
extends EditorScenePostImport

## Import-Skript für .glb-Dateien: Blenders "Active Actions Merged"-Export
## (mehrere Kind-Objekte zu einer Animation zusammengefasst) benennt das
## Ergebnis immer generisch "Animation" statt nach der eigentlichen Aktion -
## der Code erwartet aber "Activate" (siehe BaseFace.pre_activate()).
## Läuft bei jedem Reimport automatisch, kein manuelles Umbenennen mehr nötig.

const OLD_NAME := "Animation"
const NEW_NAME := "Activate"


func _post_import(scene: Node) -> Object:
	var anim_player := scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim_player == null:
		return scene

	var lib := anim_player.get_animation_library("")
	if lib != null and lib.has_animation(OLD_NAME) and not lib.has_animation(NEW_NAME):
		lib.rename_animation(OLD_NAME, NEW_NAME)

	return scene
