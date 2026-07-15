class_name GridCell
extends RefCounted
## Eine einzelne Zelle des statischen Level-Rasters - speichert bewusst NUR
## den passiven Zelltyp, nie ob gerade eine Entity darauf steht (das wissen
## die Entities selbst, siehe GameManager.get_entity_at()/get_enemy_at()).

enum Type {
	FLOOR,
	WALL,
	PILLAR,
	START,
	EXIT,
	PICKUP
}

var type: Type

func _init(p_type: Type = Type.FLOOR) -> void:
	type = p_type

func is_walkable() -> bool:
	return type != Type.WALL and type != Type.PILLAR
