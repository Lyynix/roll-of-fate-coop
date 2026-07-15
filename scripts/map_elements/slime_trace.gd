extends BaseEntity


func _on_ready() -> void:
	# Zufällige 90°-Drehung, damit nebeneinanderliegende Spuren nicht alle
	# identisch aussehen.
	rotation.y = randi_range(0, 3) * PI/2

## Verklebt beim Überrollen die Unterseite des Würfels (siehe
## Player.glue_to_bottom_face()).
func on_player_entered(entered_player: Node3D) -> void:
	(entered_player as Player).glue_to_bottom_face(self)
