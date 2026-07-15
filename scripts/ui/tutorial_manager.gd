extends Node

## Steuerung-Hinweise: rein visuell (Pfeile + Ring in der 3D-Welt), blockieren
## keine Eingaben und verschwinden sobald die jeweilige Aktion ausgeführt
## wurde. Nur einmal pro Sitzung, unabhängig von Neustarts.

const ARROWS_SCENE: PackedScene = preload("res://scenes/effects/tutorial_arrows.tscn")
const LONG_PRESS_HINT_SCENE: PackedScene = preload("res://scenes/effects/tutorial_long_press_hint.tscn")

const GHOST_HINT_DELAY_TURNS := 3
## Der Geist-Modus wird auf Touch-Geräten per Long-Press + Ziehen ausgelöst,
## am PC stattdessen per gehaltener Shift-Taste + Pfeiltasten (siehe
## Player._handle_shift_key()) - der Erklärtext muss also zur tatsächlichen
## Plattform passen, OS.has_feature("pc") deckt Desktop-Exports UND den
## Editor selbst ab (z.B. beim Testen am PC).
const GHOST_HINT_EXPLANATION_TOUCH := "Halten + Ziehen plant deinen Zug voraus"
const GHOST_HINT_EXPLANATION_PC := "Shift halten + Pfeiltasten plant deinen Zug voraus"

var _movement_shown := false
var _ghost_shown := false
var _turn_count := 0

var _movement_hint: Node3D = null
var _ghost_hint: Node3D = null
var _player: Player = null


func _ready() -> void:
	GameManager.game_started.connect(_on_game_started)


func _on_game_started() -> void:
	_clear_movement_hint()
	_clear_ghost_hint()
	_disconnect_player_signals()

	_turn_count = 0
	_player = GameManager.player as Player
	if _player == null or _movement_shown:
		return

	_movement_shown = true
	_player.turn_ended.connect(_on_turn_ended)
	_show_movement_hint()


func _disconnect_player_signals() -> void:
	if _player == null:
		return
	if _player.turn_ended.is_connected(_on_turn_ended):
		_player.turn_ended.disconnect(_on_turn_ended)
	if _player.ghost_mode_entered.is_connected(_on_ghost_entered):
		_player.ghost_mode_entered.disconnect(_on_ghost_entered)
	if _player.ghost_mode_exited.is_connected(_on_ghost_exited):
		_player.ghost_mode_exited.disconnect(_on_ghost_exited)


## Bewegungs-Hinweis: Pfeile + Ring um den Würfel, ohne Text. Verschwindet
## sobald der erste Zug abgeschlossen ist (siehe _on_turn_ended()).
func _show_movement_hint() -> void:
	_movement_hint = ARROWS_SCENE.instantiate()
	get_tree().current_scene.add_child(_movement_hint)
	_movement_hint.global_position = _player.global_position


func _on_turn_ended() -> void:
	_clear_movement_hint()
	_turn_count += 1

	if _ghost_shown or _turn_count < GHOST_HINT_DELAY_TURNS:
		return

	if _player.turn_ended.is_connected(_on_turn_ended):
		_player.turn_ended.disconnect(_on_turn_ended)
	_ghost_shown = true
	_show_ghost_hint()


## Geist-Hinweis, Schritt 1: halbtransparenter Kreis mit "Halten" - erscheint
## ein paar Züge nach Spielstart, damit der Spieler erst das normale Rollen
## verinnerlicht hat.
func _show_ghost_hint() -> void:
	_ghost_hint = LONG_PRESS_HINT_SCENE.instantiate()
	get_tree().current_scene.add_child(_ghost_hint)
	_ghost_hint.global_position = _player.global_position
	_player.ghost_mode_entered.connect(_on_ghost_entered, CONNECT_ONE_SHOT)


## Geist-Hinweis, Schritt 2: sobald tatsächlich lange gedrückt wird, weicht
## der Kreis den Pfeilen (diesmal mit Erklärtext) - verschwindet wieder,
## sobald der Geist-Modus verlassen wird.
func _on_ghost_entered() -> void:
	_clear_ghost_hint()
	_movement_hint = ARROWS_SCENE.instantiate()
	get_tree().current_scene.add_child(_movement_hint)
	_movement_hint.global_position = _player.global_position
	_movement_hint.show_label(GHOST_HINT_EXPLANATION_PC if OS.has_feature("pc") else GHOST_HINT_EXPLANATION_TOUCH)
	_player.ghost_mode_exited.connect(_on_ghost_exited, CONNECT_ONE_SHOT)


func _on_ghost_exited() -> void:
	_clear_movement_hint()


func _clear_movement_hint() -> void:
	if is_instance_valid(_movement_hint):
		_movement_hint.queue_free()
	_movement_hint = null


func _clear_ghost_hint() -> void:
	if is_instance_valid(_ghost_hint):
		_ghost_hint.queue_free()
	_ghost_hint = null
