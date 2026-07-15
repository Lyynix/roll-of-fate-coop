extends GPUParticles3D

## Blauer Partikeleffekt für die Phase-Fähigkeit: zeigt, solange der Würfel
## während des Phasens komplett ausgeblendet ist, dessen Position an - der
## einzige sichtbare Hinweis darauf, wo er sich gerade befindet. local_coords
## (siehe .tscn) sorgt dafür, dass bereits ausgestoßene Partikel automatisch
## mit dem Eltern-Node (dem Player) mitwandern, ohne dass hier pro Frame
## irgendeine Position nachgeführt werden müsste.

func _ready() -> void:
	one_shot = false
	emitting = false


## Stoppt neue Emissionen; bereits ausgestoßene Partikel klingen noch
## natürlich aus, bevor der Node sich selbst entfernt.
func stop() -> void:
	if not emitting:
		return
	emitting = false
	await get_tree().create_timer(lifetime + 0.1).timeout
	if is_instance_valid(self):
		queue_free()
