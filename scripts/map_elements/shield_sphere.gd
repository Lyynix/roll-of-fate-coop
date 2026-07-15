extends GPUParticles3D

var _active := true

func _ready() -> void:
	one_shot = false
	emitting = true
	# Fallback: Partikel beim Level-Wechsel oder Game-Over aufräumen
	GameManager.state_changed.connect(_on_state_changed)
	_burst_loop()


## Wird von HoloShieldFace.deactivate() aufgerufen, wenn der Würfel die
## Schild-Seite abrollt. Stoppt neue Emissionen; laufende Partikel spielen
## ihren Animationszyklus (cone → Sphäre) noch zu Ende.
func stop() -> void:
	if not _active:
		return
	_active = false
	emitting = false
	if GameManager.state_changed.is_connected(_on_state_changed):
		GameManager.state_changed.disconnect(_on_state_changed)
	await get_tree().create_timer(lifetime + 0.3).timeout
	if is_instance_valid(self):
		queue_free()


func _on_state_changed(state: GameManager.State) -> void:
	if state in [GameManager.State.GAME_OVER, GameManager.State.LEVEL_COMPLETE]:
		stop()


## Schaltet emitting in zufälligen Abständen ein und aus. Bei one_shot=false
## laufen bereits gestartete Partikel immer ihren vollen Lifecycle durch -
## das erzeugt unregelmäßige Schübe statt einem gleichmäßigen Strom.
## (amount_ratio wurde bewusst vermieden: es resettet den GPU-Partikelzyklus
## bei jeder Änderung, sodass Partikel ihre Zielposition nie erreichen.)
func _burst_loop() -> void:
	while _active and is_inside_tree():
		emitting = true
		await get_tree().create_timer(randf_range(0.12, 0.5)).timeout
		if not _active:
			break
		emitting = false
		await get_tree().create_timer(randf_range(0.05, 0.25)).timeout
