extends GPUParticles3D

## Lässt die Partikel dieses Kanten-Segments in eine fest vorgegebene
## Richtung fliegen (z.B. zurück zur Quelle der Gefahrenzone, Sniper oder
## Bombe). process_material ist in der Szene als resource_local_to_scene
## markiert, jede Instanz darf ihre Kopie also gefahrlos selbst verändern.
func configure(direction: Vector3, speed: float = 0.8) -> void:
	var material := process_material as ParticleProcessMaterial

	# ParticleProcessMaterial.direction wird trotz local_coords=false
	# relativ zur AKTUELLEN ROTATION des Emitters interpretiert (nur die
	# Bewegung NACH dem Spawn bleibt global) - eine Welt-Richtung muss also
	# erst in den lokalen Raum des (bei Ost/West-Kanten um 90° gedrehten)
	# Segments zurückgerechnet werden, sonst fliegen genau diese Kanten in
	# die falsche Richtung.
	var local_dir := global_transform.basis.inverse() * direction.normalized()
	material.direction = local_dir
	material.initial_velocity_min = speed
	material.initial_velocity_max = speed
