extends GPUParticles3D

## Partikel-Stream, dessen Richtung und Reichweite erst zur Laufzeit aus der
## Levelgeometrie feststehen (z.B. Bully-Sturm-Vorschau). process_material
## ist in der Szene als resource_local_to_scene markiert, jede Instanz darf
## ihre Kopie also gefahrlos selbst verändern, ohne andere zu beeinflussen.
func configure(direction: Vector3, distance_tiles: float, speed: float = 3.0) -> void:
	var dir := direction.normalized()

	# Spawnt an der Kante des Ursprungsfelds in Zielrichtung, nicht in
	# dessen Mitte. WICHTIG: additiv zur von außen bereits gesetzten
	# global_position (siehe Bully.show_prediction()) - eine direkte
	# Zuweisung würde die Position des Gegners komplett überschreiben und
	# den Stream stattdessen relativ zum Eltern-Node (current_scene, also
	# praktisch beim Weltursprung) platzieren.
	position += dir * 0.5 + Vector3.UP * 0.02

	var material := process_material as ParticleProcessMaterial
	material.direction = dir
	material.initial_velocity_min = speed
	material.initial_velocity_max = speed

	lifetime = distance_tiles / speed if speed > 0.0 else 1.0
	amount = clampi(int(distance_tiles * 8.0), 8, 64)
