extends GPUParticles3D

## Einzelner Partikel-Schuss in eine Richtung für die Turret-Anzeige - die
## Lebensdauer (1 Sekunde, in der Szene festgelegt) bleibt bewusst fix,
## unabhängig von der tatsächlichen Reichweite (Turret trifft nur das
## direkt angrenzende Feld). process_material ist als resource_local_to_scene
## markiert. Die Spawn-Position wird vollständig vom Aufrufer über
## global_position vorgegeben (siehe TurretFace.EmitPoint-Nodes) - hier kein
## zusätzlicher Versatz mehr.
func configure(direction: Vector3, speed: float = 1.0) -> void:
	var material := process_material as ParticleProcessMaterial
	material.direction = direction.normalized()
	material.initial_velocity_min = speed
	material.initial_velocity_max = speed

	one_shot = true
	emitting = true
	await get_tree().create_timer(lifetime + 0.1).timeout
	queue_free()
