extends GPUParticles3D

## Einmaliger Feuerstoß für den Flammenwerfer: startet an der von außen über
## global_position vorgegebenen EmitPoint-Position (siehe
## FlamethrowerFace._spawn_flame_burst()) und deckt distance_tiles Felder in
## Schussrichtung ab. process_material ist als resource_local_to_scene
## markiert.
func configure(direction: Vector3, distance_tiles: float, speed: float = 4.0) -> void:
	var dir := direction.normalized()

	var material := process_material as ParticleProcessMaterial
	material.direction = dir
	material.initial_velocity_min = speed * 0.75
	material.initial_velocity_max = speed

	lifetime = distance_tiles / speed if speed > 0.0 else 1.0
	amount = clampi(int(distance_tiles * 24.0), 16, 96)

	one_shot = true
	emitting = true
	await get_tree().create_timer(lifetime + 0.15).timeout
	queue_free()
