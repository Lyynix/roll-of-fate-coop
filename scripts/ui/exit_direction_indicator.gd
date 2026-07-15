extends Control
## Navigationshilfe für neue Spieler:innen: zeigt auf Etage 1-2 einen
## pulsierenden Pfeil am Bildschirmrand, der kontinuierlich zum Level-Ausgang
## zeigt (gleicher visueller Stil wie die Bewegungs-Tutorial-Pfeile, siehe
## tutorial_arrows.gd). Ab Etage 3 verschwindet der Pfeil ersatzlos - einmalig
## erscheint stattdessen ein Hinweistext, dass der Ausgang ab jetzt selbst
## gesucht werden muss.

## Abstand des Pfeils vom Bildschirmrand (Pixel).
const EDGE_MARGIN := 90.0
const HINT_VISIBLE_DURATION := 4.0
const HINT_FADE_DURATION := 0.6

@onready var arrow: Polygon2D = $Arrow
@onready var hint_label: Label = $HintLabel

var _pulse_tween: Tween


func _ready() -> void:
	arrow.hide()
	hint_label.hide()

	GameManager.floor_changed.connect(_on_floor_changed)
	_on_floor_changed(GameManager.current_floor)

	_pulse_tween = create_tween().set_loops()
	_pulse_tween.tween_property(arrow, "scale", Vector2.ONE * 1.15, 0.55).set_trans(Tween.TRANS_SINE)
	_pulse_tween.tween_property(arrow, "scale", Vector2.ONE, 0.55).set_trans(Tween.TRANS_SINE)


func _on_floor_changed(floor_number: int) -> void:
	arrow.visible = floor_number <= 2
	if floor_number == 3:
		_show_hint()


## Kurzer, selbst ausklingender Hinweistext in der oberen Bildschirmhälfte -
## erscheint einmalig beim Betreten der dritten Etage (siehe .tscn für die
## Positionierung).
func _show_hint() -> void:
	hint_label.modulate.a = 1.0
	hint_label.show()

	var tween := create_tween()
	tween.tween_interval(HINT_VISIBLE_DURATION)
	tween.tween_property(hint_label, "modulate:a", 0.0, HINT_FADE_DURATION)
	tween.tween_callback(hint_label.hide)


## Bestimmt jeden Frame neu, in welche Bildschirmrichtung der Level-Ausgang
## liegt - über die tatsächliche Kamera-Projektion (unproject_position()),
## nicht über eine von Hand nachgerechnete isometrische Projektion, damit das
## robust bleibt, falls sich Kamera-Winkel/-Zoom je einmal ändern. Der Pfeil
## sitzt danach immer auf einem festen Radius um die Bildschirmmitte (reiner
## Kompass, nicht nur bei tatsächlich unsichtbarem Ausgang).
func _process(_delta: float) -> void:
	if not arrow.visible:
		return

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var exit_world := LevelManager.grid_to_world(LevelManager.exit_position) + Vector3.UP * 0.5
	var screen_pos := camera.unproject_position(exit_world)
	var center := size * 0.5

	# Liegt das Ziel hinter der Kamera, ist die Projektion gespiegelt/unbrauchbar -
	# der Vektor wird stattdessen durch die Bildschirmmitte gespiegelt, damit der
	# Pfeil trotzdem eine sinnvolle Richtung zeigt statt wild zu springen.
	if camera.is_position_behind(exit_world):
		screen_pos = center - (screen_pos - center)

	var to_target := screen_pos - center
	if to_target.length() < 1.0:
		to_target = Vector2.UP

	var direction := to_target.normalized()
	var radius := minf(size.x, size.y) * 0.5 - EDGE_MARGIN
	arrow.position = center + direction * radius
	# Das Dreieck zeigt in seiner Ruhelage nach oben (lokal -Y) - PI/2 gleicht
	# den Versatz zwischen Vector2.angle() (0 = +X) und dieser Ruherichtung aus.
	arrow.rotation = direction.angle() + PI / 2.0
