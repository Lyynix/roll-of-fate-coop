extends CanvasLayer

@onready var floor_label: Label = $FloorLabel
@onready var score_label: Label = $ScoreLabel
@onready var enemy_turn_label: Label = $EnemyTurnLabel
@onready var vignette: ColorRect = $Vignette
@onready var enemy_vignette: ColorRect = $EnemyVignette
@onready var game_over_screen: Control = $GameOverScreen
@onready var restart_button: Button = $GameOverScreen/CenterContainer/VBoxContainer/RestartButton
@onready var pause_button: Button = $PauseButton

var _vignette_material: ShaderMaterial
var _enemy_vignette_material: ShaderMaterial
var _vignette_tween: Tween
var _enemy_turn_tween: Tween

var _world_env: WorldEnvironment
var _main_menu: Node


func _ready() -> void:
	_vignette_material = vignette.material as ShaderMaterial
	_enemy_vignette_material = enemy_vignette.material as ShaderMaterial

	# WorldEnvironment per Name-Suche finden - keine direkte Referenz nötig,
	# da HUD als CanvasLayer kein Elternteil der 3D-Szene ist.
	_world_env = get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if _world_env and _world_env.environment:
		_world_env.environment.adjustment_enabled = true
		_world_env.environment.adjustment_saturation = 1.0

	GameManager.player_hp_changed.connect(_on_player_hp_changed)
	GameManager.floor_changed.connect(_on_floor_changed)
	GameManager.score_changed.connect(_on_score_changed)
	GameManager.state_changed.connect(_on_state_changed)
	restart_button.pressed.connect(_on_restart_pressed)
	pause_button.pressed.connect(_on_pause_pressed)

	# Sibling unter Main.tscn - kein direkter Node-Pfad, da HUD unabhängig
	# von MainMenu instanziert werden kann (z.B. im Test-Runner).
	_main_menu = get_tree().root.find_child("MainMenu", true, false)

	_on_floor_changed(GameManager.current_floor)
	_on_player_hp_changed(GameManager.player_hp, GameManager.max_player_hp)
	_on_score_changed(GameManager.score)
	game_over_screen.hide()


func _on_floor_changed(floor_number: int) -> void:
	floor_label.text = "Etage %d" % floor_number


func _on_score_changed(new_score: int) -> void:
	score_label.text = "%d Pkt." % new_score


## Roter Innen-Schatten als Warnung bei 1 HP.
func _on_player_hp_changed(current: int, _max_hp: int) -> void:
	var target_intensity := 1.0 if current == 1 else 0.0

	if _vignette_tween and _vignette_tween.is_running():
		_vignette_tween.kill()

	_vignette_tween = create_tween()
	_vignette_tween.tween_property(_vignette_material, "shader_parameter/intensity", target_intensity, 0.3)


func _on_state_changed(new_state: GameManager.State) -> void:
	game_over_screen.visible = new_state == GameManager.State.GAME_OVER

	# "Nicht dran"-Indikator: blendet ein, sobald DIESES Gerät gerade nicht
	# am Zug ist - im Koop also auch während der Zug-Phase des jeweils
	# anderen Spielers (SECONDARY_TURN), nicht nur während RESOLVING/ENEMY_TURN.
	# GAME_OVER / LEVEL_COMPLETE sind kurzlebige Übergänge oder durch eigene
	# Screens abgedeckt.
	if new_state not in [GameManager.State.PLAYER_TURN,
						GameManager.State.SECONDARY_TURN,
						GameManager.State.RESOLVING,
						GameManager.State.ENEMY_TURN]:
		return

	var waiting := not GameManager.is_my_turn()
	if waiting:
		enemy_turn_label.text = GameManager.waiting_reason_text()
	_set_enemy_turn_indicator(waiting)


## Blendet Sättigungs-Reduktion, dunkle Rand-Vignette und das "Gegner
## zieht"-Label sanft ein oder aus.
func _set_enemy_turn_indicator(active: bool) -> void:
	var target_intensity := 0.22 if active else 0.0
	var target_sat := 0.5 if active else 1.0
	var target_alpha := 1.0 if active else 0.0

	if _enemy_turn_tween and _enemy_turn_tween.is_running():
		_enemy_turn_tween.kill()

	_enemy_turn_tween = create_tween().set_parallel(true)
	_enemy_turn_tween.tween_property(_enemy_vignette_material, "shader_parameter/intensity", target_intensity, 0.35)
	_enemy_turn_tween.tween_property(enemy_turn_label, "modulate:a", target_alpha, 0.35)
	if _world_env and _world_env.environment:
		_enemy_turn_tween.tween_property(_world_env.environment, "adjustment_saturation", target_sat, 0.35)


func _on_restart_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	GameManager.start_game()


func _on_pause_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	if _main_menu and _main_menu.has_method("open"):
		_main_menu.open()
