extends Node3D

@onready var level_parent: Node3D = $LevelParent

func _ready() -> void:
	GameManager.register_level_parent(level_parent)
