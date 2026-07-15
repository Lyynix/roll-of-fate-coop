extends Node3D

@onready var visuals: Node3D = $Visuals
@onready var label: Label3D = $Label3D

const ARROW_DISTANCE := 0.9
const ARROW_HEIGHT := 1.0

## Welche Richtungen gezeigt werden - Node-Name im "Visuals"-Kind muss passen.
const ARROW_DIRECTIONS := {
	"ArrowForward": Vector3(0, 0, -1),
	"ArrowBack": Vector3(0, 0, 1),
	"ArrowRight": Vector3(1, 0, 0),
	"ArrowLeft": Vector3(-1, 0, 0),
}

var _tween: Tween


func _ready() -> void:
	_orient_arrows()
	label.hide()

	_tween = create_tween().set_loops()
	_tween.tween_property(visuals, "scale", Vector3.ONE * 1.15, 0.55).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(visuals, "scale", Vector3.ONE, 0.55).set_trans(Tween.TRANS_SINE)


## Positioniert + rotiert die Pfeile programmatisch (lokale +Y-Achse des
## Kegels = Spitze zeigt nach außen) - zuverlässiger als handgerechnete
## Transform3D-Matrizen direkt in der .tscn-Datei.
func _orient_arrows() -> void:
	for arrow_name in ARROW_DIRECTIONS:
		var dir: Vector3 = ARROW_DIRECTIONS[arrow_name]
		var arrow: Node3D = visuals.get_node(arrow_name)
		arrow.position = dir * ARROW_DISTANCE + Vector3.UP * ARROW_HEIGHT
		arrow.basis = _basis_pointing(dir)


static func _basis_pointing(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := Vector3.UP.cross(y).normalized()
	var z := x.cross(y)
	return Basis(x, y, z)


## Zeigt einen kurzen Erklärtext über den Pfeilen an (nur für den
## Geist-Hinweis genutzt - beim ersten Bewegungs-Hinweis bleibt er leer).
func show_label(text: String) -> void:
	label.text = text
	label.show()
