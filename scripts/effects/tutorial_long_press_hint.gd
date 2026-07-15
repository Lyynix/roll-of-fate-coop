extends Node3D

@onready var disc: MeshInstance3D = $Disc
@onready var label: Label3D = $Label3D


func _ready() -> void:
	# Touch-Geräte: Long-Press. PC (Export oder Editor): Shift-Taste - siehe
	# Player._handle_shift_key().
	label.text = "Shift" if OS.has_feature("pc") else "Halten"

	var tween := create_tween().set_loops()
	tween.tween_property(disc, "scale", Vector3.ONE * 1.2, 0.6).set_trans(Tween.TRANS_SINE)
	tween.tween_property(disc, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_SINE)
