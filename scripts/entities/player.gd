class_name Player
extends Node3D
## Der rollende Würfel: wertet Swipe-/Tastatur-Eingaben aus, führt die
## physische 90°-Rollbewegung über einen verschiebbaren Pivot aus
## (siehe _perform_roll_step()) und verwaltet die 6 Slot-Marker samt
## aufgesteckter Würfelseiten (Deckbuilding). Welche Seite oben/unten liegt,
## wird nie als eigener Zustand mitgeführt, sondern immer frisch aus den
## Slot-Weltpositionen abgeleitet (siehe _extreme_slot()).

const SLIME_TRACE_SCENE: PackedScene = preload("res://scenes/map_elements/slime_trace.tscn")
const PHASE_PARTICLES_SCENE: PackedScene = preload("res://scenes/map_elements/phase_particles.tscn")

var touch_start_pos := Vector2.ZERO

## Long-Press-Schwellwert für den Planungs-Ghost-Modus.
const LONG_PRESS_MS := 400
## Größerer Mindestweg pro Ghost-Schritt, damit man beim Ziehen nicht
## versehentlich zu viele Schritte auf einmal auslöst.
const GHOST_STEP_MULTIPLIER := 3.0
var _in_ghost_mode: bool = false
var _ghost: Node3D = null
var _ghost_drag_anchor: Vector2

## Letzte bekannte Finger-Position (Touch-Down oder Drag) - als Ghost-Anker
## nötig, falls der Long-Press-Timer auslöst während der Finger stillhält
## (kein Drag-Event in dem Fall).
var _current_touch_pos: Vector2 = Vector2.ZERO
## Erhöht sich bei jedem Touch-Down/-Up - macht einen zu dem Zeitpunkt noch
## laufenden Long-Press-Timer ungültig (neuer Touch oder vorzeitig losgelassen).
var _touch_session_id := 0

## Wird zu Beginn jeder Bewegungsart (roll/dash/phase) mit der Ziel-
## Weltposition gefeuert - teilt Positionswechsel frühzeitig mit, noch bevor
## die Roll-Animation läuft.
signal roll_started(target_pos: Vector3)
signal turn_ended
signal ghost_mode_entered
signal ghost_mode_exited

## Ob gerade eine Spieler-Eingabe angenommen wird - false während Animationen,
## Gegner-Zügen und (Koop) während auf die Host-Antwort gewartet wird.
var awaiting_input: bool = false

## Letzte tatsächlich ausgeführte Bewegungsrichtung ("Blickrichtung"),
## z.B. für den Flammenwerfer relevant.
var last_direction: Vector3 = Vector3.FORWARD

@export var min_swipe_distance := 15.0
@export var roll_speed : float = 5.5
@export var grid_size : float = 1.0

@onready var pivot = $Pivot
@onready var cube = $Pivot/CubeMesh
@onready var camera_base = $CameraBase

@onready var slots = {
	1: $Pivot/CubeMesh/Slot_1,
	2: $Pivot/CubeMesh/Slot_2,
	3: $Pivot/CubeMesh/Slot_3,
	4: $Pivot/CubeMesh/Slot_4,
	5: $Pivot/CubeMesh/Slot_5,
	6: $Pivot/CubeMesh/Slot_6
}

@export_category("Testing")
@export var test_override_slot : Marker3D
@export var test_override_scene : PackedScene

## Koop: true für die zweite, per Netzwerk nachgespielte Würfel-Instanz (den
## jeweils anderen Spieler). Muss VOR add_child() gesetzt werden, da _ready()
## sofort beim Einhängen in den Baum läuft. Ein Puppet bekommt nie lokale
## Eingaben und entscheidet nie selbst über den nächsten Spielzustand -
## siehe _ready()/_input().
@export var is_remote_puppet: bool = false

## Ausgangs-Orientierung des Würfels, direkt beim Laden erfasst - roll()
## bakt jede Drehung dauerhaft in cube.transform.basis hinein (siehe
## _perform_roll_step()), ohne Reset bliebe der Würfel nach einem Neustart
## also in der Rotation vom Vorlauf stehen.
var _initial_cube_position: Vector3
var _initial_cube_basis: Basis

## Ausgangs-Fähigkeit pro Slot (1-6), direkt beim Laden erfasst (nach einem
## eventuellen Test-Override) - Pickups tauschen Seiten während des Runs per
## attach_to_bottom() aus, ohne Reset blieben diese Ersetzungen über einen
## Neustart hinweg bestehen.
var _initial_slot_scenes: Dictionary = {}

func _ready() -> void:
	if is_remote_puppet:
		# Puppet: nur registrieren, keine Turn-Signale - es spielt ausschließlich
		# vom Host relayte Aktionen nach (siehe GameManager), entscheidet nie
		# selbst über den nächsten Zustand.
		GameManager.register_remote_player(self)
	else:
		# Beide Signale IMMER verbinden, unabhängig von der aktuellen Rolle:
		# _ready() läuft schon beim App-Start (Main.tscn lädt sofort), lange
		# bevor man sich überhaupt mit jemandem verbunden hat - NetworkManager.role
		# ist zu diesem Zeitpunkt immer noch NONE, ein einmaliger Rollen-Check
		# hier wäre also für die gesamte Laufzeit der Kugel falsch. Stattdessen
		# prüft jeder Handler die Rolle FRISCH beim tatsächlichen Feuern des
		# jeweiligen Signals (siehe _on_player_turn_started()/_on_secondary_turn_started()).
		GameManager.player_turn_started.connect(_on_player_turn_started)
		GameManager.secondary_turn_started.connect(_on_secondary_turn_started)
		GameManager.register_player(self)

	_initial_cube_position = cube.position
	_initial_cube_basis = cube.transform.basis

	if test_override_scene != null and test_override_slot != null:
		slot_scene(test_override_slot, test_override_scene)

	# Nach einem eventuellen Test-Override erfassen, damit das "Original"
	# wirklich dem tatsächlichen Spielstart entspricht (auch im Test-Runner).
	for slot_name in slots:
		var slot: Marker3D = slots[slot_name]
		if slot.get_child_count() > 0:
			var face := slot.get_child(0) as BaseFace
			_initial_slot_scenes[slot_name] = face.source_scene


## Setzt die sichtbare Würfel-Rotation auf den Ausgangszustand zurück (bei
## "Neues Spiel" und Neustart nach Game Over) - siehe _initial_cube_basis.
func reset_orientation() -> void:
	pivot.position = Vector3.ZERO
	pivot.quaternion = Quaternion.IDENTITY
	cube.position = _initial_cube_position
	cube.transform.basis = _initial_cube_basis


## Setzt alle 6 Würfelseiten auf ihre Ausgangs-Fähigkeiten zurück (bei
## "Neues Spiel" und Neustart nach Game Over) - siehe _initial_slot_scenes.
func reset_faces() -> void:
	for slot_name in _initial_slot_scenes:
		var scene: PackedScene = _initial_slot_scenes[slot_name]
		if scene != null:
			slot_scene(slots[slot_name], scene)

func _on_player_turn_started() -> void:
	if is_remote_puppet:
		return
	# Dieses Signal bedeutet "der Host ist dran" - im Koop betrifft das
	# nicht die eigene Kugel des Secondary-Spielers (die wartet auf
	# _on_secondary_turn_started()). Singleplayer/Host: unverändert.
	if NetworkManager.role == NetworkManager.Role.SECONDARY:
		return
	awaiting_input = true


func _on_secondary_turn_started() -> void:
	if is_remote_puppet:
		return
	# Nur relevant für die eigene Kugel des Secondary-Spielers - auf dem
	# Host-Gerät feuert dieses Signal zwar auch (siehe GameManager.
	# _begin_secondary_turn(), nicht rollen-abhängig), betrifft dort aber
	# nicht die eigene (Host-)Kugel.
	if NetworkManager.role != NetworkManager.Role.SECONDARY:
		return
	awaiting_input = true

func _input(event):
	if is_remote_puppet:
		return
	if event is InputEventKey:
		_handle_key_input(event)
		return

	if event is InputEventScreenDrag:
		_current_touch_pos = event.position
		_handle_drag(event)
		return

	if not event is InputEventScreenTouch: return

	if event.pressed:
		# Druck-Position immer merken, auch während der Gegner-Zug noch läuft -
		# sonst würde beim Loslassen mit einer veralteten Position gerechnet.
		touch_start_pos = event.position
		_current_touch_pos = event.position
		_touch_session_id += 1
		_start_long_press_timer(_touch_session_id)
	else:
		_touch_session_id += 1 # macht einen noch laufenden Long-Press-Timer ungültig
		if _in_ghost_mode:
			_clear_ghost()
		elif awaiting_input:
			_handle_swipe(event.position - touch_start_pos)


## Wechselt nach LONG_PRESS_MS automatisch in den Ghost-Modus, auch wenn der
## Finger währenddessen einfach nur stillhält (nicht erst beim Ziehen) -
## intuitiver und passt besser zum Tutorial-Hinweis ("Halten").
func _start_long_press_timer(session_id: int) -> void:
	if not awaiting_input:
		return
	await get_tree().create_timer(LONG_PRESS_MS / 1000.0).timeout
	if session_id != _touch_session_id:
		return # Finger inzwischen losgelassen oder neuer Touch gestartet
	if not _in_ghost_mode and awaiting_input:
		_enter_ghost_mode(_current_touch_pos)


## Ghost-Schritte beim Ziehen des Fingers - die Long-Press-Erkennung selbst
## liegt in _start_long_press_timer().
func _handle_drag(event: InputEventScreenDrag) -> void:
	if not awaiting_input:
		return

	if _in_ghost_mode:
		var delta := event.position - _ghost_drag_anchor
		if delta.length() >= min_swipe_distance * GHOST_STEP_MULTIPLIER:
			_ghost.call("step", _swipe_to_direction(delta))
			_ghost_drag_anchor = event.position


## Bildschirm-Wischrichtung -> Weltachse. Die Kamera ist um 45° gedreht
## (isometrischer Look): ein Wisch nach rechts-oben entspricht logisch
## Vector3.FORWARD, die übrigen Quadranten analog. Gemeinsame Zuordnung für
## normalen Swipe und Ghost-Drag.
func _swipe_to_direction(swipe: Vector2) -> Vector3:
	if swipe.x > 0 and swipe.y < 0:
		return Vector3.FORWARD
	elif swipe.x > 0 and swipe.y > 0:
		return Vector3.RIGHT
	elif swipe.x < 0 and swipe.y > 0:
		return Vector3.BACK
	return Vector3.LEFT


func _enter_ghost_mode(current_drag_pos: Vector2) -> void:
	_in_ghost_mode = true
	_ghost_drag_anchor = current_drag_pos
	# GHOST_SCENE als Klassen-Konstante wäre ein zirkulärer Lade-Fehler
	# (GhostPlayer ↔ Player), daher Preload erst beim ersten Aufruf.
	var ghost_scene := load("res://scenes/effects/ghost_player.tscn") as PackedScene
	_ghost = ghost_scene.instantiate()
	get_tree().current_scene.add_child(_ghost)
	_ghost.call("init", self)
	ghost_mode_entered.emit()


func _clear_ghost() -> void:
	_in_ghost_mode = false
	if _ghost != null:
		_ghost.call("clear")
		_ghost = null
	ghost_mode_exited.emit()

## Pfeiltasten zum Steuern am Desktop - direkte Alternative zum Swipe.
## Shift wird gesondert behandelt (Tastatur-Äquivalent zum Long-Press, siehe
## _handle_shift_key()) und bleibt deshalb von der awaiting_input-Sperre
## unten unberührt: Loslassen muss den Geist-Modus auch dann noch verlassen
## können, wenn awaiting_input inzwischen falsch geworden wäre.
func _handle_key_input(event: InputEventKey) -> void:
	if event.keycode == KEY_SHIFT:
		_handle_shift_key(event)
		return

	if not event.pressed or event.echo or not awaiting_input:
		return

	var direction := Vector3.ZERO
	match event.keycode:
		KEY_UP:
			direction = Vector3.FORWARD
		KEY_RIGHT:
			direction = Vector3.RIGHT
		KEY_DOWN:
			direction = Vector3.BACK
		KEY_LEFT:
			direction = Vector3.LEFT
	if direction == Vector3.ZERO:
		return

	# Im Geist-Modus (Shift gehalten) bewegen die Pfeiltasten den Geist statt
	# direkt zu rollen - Pendant zu _handle_drag() bei Touch-Eingabe.
	if _in_ghost_mode:
		_ghost.call("step", direction)
	else:
		_try_roll(direction)


## Tastatur-Äquivalent zum Long-Press: Shift halten aktiviert den
## Planungs-Modus, Loslassen verwirft ihn wieder - Pfeiltasten bewegen den
## Geist währenddessen (siehe _handle_key_input()).
func _handle_shift_key(event: InputEventKey) -> void:
	if event.echo:
		return

	if event.pressed:
		if _in_ghost_mode or not awaiting_input:
			return
		_enter_ghost_mode(_current_touch_pos)
	elif _in_ghost_mode:
		_clear_ghost()


## Koop: der Secondary-Spieler darf nie lokal rollen (Host-Autorität) -
## schickt stattdessen eine Zugabsicht an den Host und sperrt die eigene
## Eingabe, bis dessen Antwort (turn_action/turn_rejected, siehe
## GameManager) eintrifft. Host (und Singleplayer) rollen unverändert direkt.
## Gemeinsamer Einstiegspunkt für _handle_swipe()/_handle_key_input(), damit
## diese Weiche nicht doppelt gepflegt werden muss.
func _try_roll(direction: Vector3) -> void:
	if NetworkManager.role == NetworkManager.Role.SECONDARY:
		if not awaiting_input:
			return
		awaiting_input = false
		NetworkManager.send({"type": "turn_request", "direction": direction})
	else:
		roll(direction)


func _handle_swipe(swipe_vector: Vector2) -> void:
	if swipe_vector.length() < min_swipe_distance:
		return
	_try_roll(_swipe_to_direction(swipe_vector))


## bypass_awaiting_input: Koop - überspringt die "bin ich dran"-Sperre, für das
## Nachspielen bereits autoritativ entschiedener Züge (Host wendet Secondarys
## Anfrage auf sein Puppet an; beide Seiten spielen bestätigte turn_action-
## Nachrichten nach - die eigene Kugel hat awaiting_input dabei schon selbst
## auf false gesetzt, siehe GameManager). dash()/phase_roll() brauchen kein
## Äquivalent, die haben nie eine awaiting_input-Sperre (nur über modify_roll()
## erreichbar, das schon hinter dieser Sperre liegt).
## Rückgabewert: true = Zug wurde verbraucht (normaler Roll oder Übergabe an
## Dash/Phase, die selbst konsumieren), false = abgelehnt (Wand/Gegner im Weg,
## oder awaiting_input-Sperre) - für Koop nötig, damit der Host nach einer
## Secondary-Anfrage zuverlässig zwischen "angenommen" und "abgelehnt"
## unterscheiden kann (siehe GameManager, turn_request-Handler).
func roll(direction: Vector3, dynamic_roll_speed = roll_speed, bypass_awaiting_input: bool = false) -> bool:
	if not bypass_awaiting_input and not awaiting_input: return false

	var current_top_face := get_top_face_module()
	if current_top_face and not current_top_face.is_disabled() and current_top_face.modify_roll(self, direction):
		return true

	var target_grid_pos := LevelManager.world_to_grid(global_position + direction * grid_size)
	if not LevelManager.is_walkable(target_grid_pos):
		return false

	# Felder mit Gegnern können nicht angerollt werden (blockieren wie eine
	# Wand). Ramm man dabei einen Schleim-Würfel, klebt das als Strafe alle
	# Würfelseiten fest (wie eine Schleimspur) und der Schleim-Würfel stirbt.
	var target_world := LevelManager.grid_to_world(target_grid_pos)
	var target_enemy := GameManager.get_enemy_at(Vector3i(target_world))
	if target_enemy != null:
		if target_enemy is Slime:
			glue_all_faces()
			target_enemy.die()
		return false

	# Koop: die jeweils andere Spieler-Kugel blockiert wie eine Wand - kein
	# Durchrollen. Bleibt im Singleplayer wirkungslos (remote_player ist
	# dort immer null).
	var other_player := GameManager.remote_player if self == GameManager.player else GameManager.player
	if other_player != null and Vector3i(other_player.global_position) == Vector3i(target_world):
		return false

	var next_top_face := get_next_top_face(direction)
	_begin_move(direction, current_top_face, next_top_face)
	roll_started.emit(target_world)

	await _perform_roll_step(direction, dynamic_roll_speed)

	_finish_move(direction, current_top_face, next_top_face)
	return true


## Gemeinsamer Auftakt aller Bewegungsarten (roll/dash/phase): sperrt weitere
## Eingaben, merkt die Blickrichtung und benachrichtigt VOR der Animation die
## abtretende (deactivate) sowie die kommende Oberseite (pre_activate).
func _begin_move(direction: Vector3, current_top_face: BaseFace, next_top_face: BaseFace) -> void:
	awaiting_input = false
	last_direction = direction
	print("[Player] Starte Bewegung in Richtung ", direction)

	if current_top_face and not current_top_face.is_disabled():
		current_top_face.deactivate()
	if next_top_face and not next_top_face.is_disabled():
		next_top_face.pre_activate()


## Gemeinsamer Abschluss aller Bewegungsarten: benachrichtigt NACH der
## Animation die Seiten (post_deactivate/activate), gibt eine eventuell an
## der neuen Unterseite klebende Schleimspur zurück auf den Boden und meldet
## den fertigen Zug an den GameManager.
func _finish_move(direction: Vector3, current_top_face: BaseFace, next_top_face: BaseFace) -> void:
	if current_top_face and not current_top_face.is_disabled():
		current_top_face.post_deactivate()
	if next_top_face and not next_top_face.is_disabled():
		next_top_face.activate()

	# Die neue Unterseite hat gerade wieder Bodenkontakt: eine eventuell
	# geklebte Schleimspur wird hier zurück auf den Boden gegeben.
	var new_bottom_face := get_bottom_face_module()
	if new_bottom_face and new_bottom_face.is_disabled():
		_release_glued_object(new_bottom_face)

	turn_ended.emit()
	GameManager.on_player_turn_ended(direction)


## Führt eine einzelne 90°-Rollbewegung aus (nur Pivot-Rotation, Kamera- und
## Positions-Cleanup). Enthält keinen Walkability-Check und keine
## Face-Aktivierung - wird von roll() für den Normalfall genutzt und von
## Fähigkeiten wie Dash, die mehrere Rollschritte hintereinander brauchen.
func _perform_roll_step(direction: Vector3, dynamic_roll_speed: float) -> void:
	SoundManager.play_sfx("player_move")

	# 1. Pivot an die untere Kante verschieben, über die abgerollt wird - der
	# Würfel selbst wird gegenversetzt, damit seine Weltposition zunächst
	# unverändert bleibt.
	var pivot_offset = direction * grid_size / 2
	pivot.position = pivot_offset
	cube.position = Vector3.UP * (grid_size / 2) - pivot_offset

	# 2. 90°-Rotation um die Kantenachse und Kamera-Nachführung parallel tweenen.
	var axis = direction.cross(Vector3.DOWN).normalized()
	var target_quat = Quaternion(axis, PI/2)

	var tween = create_tween().set_parallel(true)
	tween.tween_property(pivot, "quaternion", target_quat, 1.0 / dynamic_roll_speed)

	var target_cam_pos = camera_base.global_position + (direction * grid_size)
	tween.tween_property(camera_base, "global_position", target_cam_pos, 1.0 / dynamic_roll_speed)

	await tween.finished

	# 3. Cleanup: die neue Weltposition auf den Wurzel-Node übertragen, Pivot
	# und Kamera in den Ursprung zurücksetzen und die erreichte Rotation
	# dauerhaft in die CubeMesh-Basis "backen" - der Wurzel-Node behält so
	# immer seine reine Raster-Position.
	global_position += direction * grid_size

	var current_basis = cube.global_transform.basis
	pivot.position = Vector3.ZERO
	pivot.quaternion = Quaternion.IDENTITY
	cube.position = Vector3(0, grid_size / 2.0, 0)
	cube.global_transform.basis = current_basis
	camera_base.position = Vector3.ZERO


## Dash-Fähigkeit: rollt steps (1 oder 2) Felder hintereinander in dieselbe
## Richtung. Gegner auf dem Weg werden vorher bis zum nächsten Hindernis
## weggeschleudert und nehmen Aufprallschaden. Bei 2 vollen Schritten landet
## (durch die doppelte 90°-Drehung) die aktuelle Unterseite oben - eine
## Seite wird dabei "übersprungen".
func dash(direction: Vector3, steps: int) -> void:
	var current_top_face := get_top_face_module()
	var next_top_face := get_bottom_face_module() if steps >= 2 else get_next_top_face(direction)
	_begin_move(direction, current_top_face, next_top_face)
	roll_started.emit(global_position + direction * grid_size * steps)

	for i in range(steps):
		_knock_back_enemy_at(Vector3i(global_position) + Vector3i(direction.normalized()), direction)
		await _perform_roll_step(direction, roll_speed)

	_finish_move(direction, current_top_face, next_top_face)


## Schleudert einen an pos stehenden Gegner bis zum nächsten Hindernis in
## Richtung direction und fügt ihm Aufprallschaden zu.
func _knock_back_enemy_at(pos: Vector3i, direction: Vector3) -> void:
	var enemy := GameManager.get_enemy_at(pos)
	if enemy == null:
		return

	var dir := Vector3i(direction.normalized())
	enemy.global_position = Vector3(LevelManager.furthest_walkable(pos, dir))
	enemy.take_damage(1)


## Strafe für riskanten Umgang mit Schleim-Würfeln: klebt an JEDE der 6
## Seiten eine frische Schleimspur (dieselbe Mechanik wie das normale
## Überrollen einer Schleimspur, siehe glue_to_bottom_face()) - jede Seite
## löst sich also ganz normal wieder, sobald sie beim Rollen erneut
## Bodenkontakt hat. Slots, die bereits anderweitig verklebt sind, werden
## nicht doppelt beklebt.
func glue_all_faces() -> void:
	var top_face := get_top_face_module()

	for slot_name in slots:
		var marker : Marker3D = slots[slot_name]
		if marker.get_child_count() != 1:
			continue # leer oder schon verklebt - nichts zu tun

		var face := marker.get_child(0)
		# Die oben liegende Seite ist gerade aktiv (z.B. HoloShield mit
		# laufendem Partikeleffekt) - normalerweise beendet erst deactivate()
		# im nächsten roll() diesen Zustand, aber is_disabled() blockiert das
		# nach dem Ankleben hier für immer. Also jetzt sofort deaktivieren.
		if face == top_face and face.has_method("deactivate"):
			face.deactivate()

		var trace := SLIME_TRACE_SCENE.instantiate()
		marker.add_child(trace)
		# Frisch instanziert lief bereits BaseEntity._ready() und hat sich
		# selbst registriert - wie bei glue_to_bottom_face() darf eine am
		# Würfel klebende Spur aber nicht als lose Entity in der Welt
		# zählen (sonst z.B. fälschlich als Pickup an der aktuellen
		# Spielerposition erkannt, deren Slots ja Teil des Würfels sind).
		GameManager.unregister_entity(trace)
		trace.position = Vector3.UP * 0.1
		trace.rotation = Vector3.ZERO


## Phase-Fähigkeit: gleitet steps Felder weit stur in direction weiter, auch
## durch Wände/Säulen/Gegner hindurch (siehe PhaseFace.modify_roll(), keine
## Walkability-Prüfung mehr). Unabhängig von der Distanz dreht sich der
## Würfel dabei um genau EINE Seite weiter (wie ein einzelner Rollschritt) -
## wichtig gegen den Dauer-Phase-Softlock: läge nach der Bewegung wieder
## dieselbe Seite oben, könnte man nie mehr aufhören zu phasen. Während der
## Bewegung ist der Würfel komplett unsichtbar, blaue Partikel markieren
## seine Position (siehe _animate_phase_effect()).
func phase_roll(direction: Vector3, steps: int) -> void:
	var current_top_face := get_top_face_module()
	var next_top_face := get_next_top_face(direction)
	_begin_move(direction, current_top_face, next_top_face)
	roll_started.emit(global_position + direction * grid_size * steps)

	_animate_phase_effect(float(steps) / roll_speed)
	await _perform_phase_slide(direction, steps)

	_finish_move(direction, current_top_face, next_top_face)


## Führt die Phase-Bewegung aus: schiebt den Wurzel-Node in einem Zug um
## steps Felder und dreht den Würfel dabei um seine eigene Mitte genau 90°
## weiter - bewusst KEIN _perform_roll_step() pro Feld, der Würfel soll
## sichtbar gleiten statt physisch zu rollen. Die Kamera hängt am
## Wurzel-Node und fährt automatisch mit.
func _perform_phase_slide(direction: Vector3, steps: int) -> void:
	SoundManager.play_sfx("player_move")

	var duration := float(steps) / roll_speed
	var axis := direction.cross(Vector3.DOWN).normalized()
	var target_quat: Quaternion = Quaternion(axis, PI / 2) * cube.basis.get_rotation_quaternion()

	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "global_position",
		global_position + direction * grid_size * steps, duration)
	tween.tween_property(cube, "quaternion", target_quat, duration)
	await tween.finished


## Visueller Phase-Effekt: der komplette Würfel (Schale + gerade aufgesteckte
## Ober-/Unterseite) verschwindet komplett, ein blauer Partikeleffekt (siehe
## phase_particles.gd) markiert an seiner Stelle die Position, solange er
## unsichtbar ist. Läuft parallel zur Gleit-Bewegung (nicht awaited); duration
## ist deren tatsächliche Dauer, damit der Effekt exakt die gesamte Bewegung
## abdeckt. Aufgeteilt in drei Phasen relativ zu duration:
##   0%–15%:  Würfel blendet aus (Alpha 1→0), Partikel setzen ein.
##   15%–75%: Würfel bleibt unsichtbar - die Partikel sind der einzige
##            sichtbare Hinweis auf seine (sich bewegende) Position.
##   75%–100%: Würfel blendet wieder ein (Alpha 0→1), Partikel stoppen und
##             klingen aus (siehe PhaseParticles.stop()).
##
## GeometryInstance3D.transparency wirkt nur, wenn das zugehörige Material
## bereits Alpha-Blending aktiviert hat - die aus GLBs importierten Materialien
## sind aber opak, ein reines Tweenen dieser Property bliebe daher unsichtbar
## (derselbe Grund, aus dem GhostPlayer.init() ein eigenes Alpha-Material statt
## nur `transparency` nutzt). Jedes Mesh bekommt hier deshalb kurzzeitig ein
## dupliziertes, alpha-fähiges Material-Override, dessen Alpha getweent wird;
## danach wird das Override wieder entfernt (Original-Material bleibt unberührt).
## Frisch pro Aufruf gesammelt statt gecacht, da sich die aufgesteckte Seite
## durch Deckbuilding jederzeit ändern kann.
func _animate_phase_effect(duration: float) -> void:
	const FADE_OUT_RATIO := 0.15
	const FADE_IN_START_RATIO := 0.75

	var fade_out_duration := duration * FADE_OUT_RATIO
	var hidden_duration := duration * (FADE_IN_START_RATIO - FADE_OUT_RATIO)
	var fade_in_duration := duration * (1.0 - FADE_IN_START_RATIO)

	var particles := PHASE_PARTICLES_SCENE.instantiate()
	add_child(particles)
	particles.emitting = true

	var mesh_instances := cube.find_children("*", "MeshInstance3D", true, false)
	if not mesh_instances.is_empty():
		var overrides: Array[StandardMaterial3D] = []
		for mesh_instance in mesh_instances:
			var base_mat: Material = mesh_instance.get_active_material(0)
			var override: StandardMaterial3D = base_mat.duplicate() if base_mat is StandardMaterial3D else StandardMaterial3D.new()
			override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mesh_instance.material_override = override
			overrides.append(override)

		var tween := create_tween()
		for override in overrides:
			tween.parallel().tween_property(override, "albedo_color:a", 0.0, fade_out_duration)

		# Zusätzlich zum Alpha-Tween hart ausblenden: Specular-/Fresnel-Anteile
		# des PBR-Materials bleiben bei Albedo-Alpha 0 je nach Blickwinkel und
		# Beleuchtung noch schwach sichtbar (reines Alpha-Blending reicht
		# nicht für "komplett unsichtbar") - visible=false garantiert das.
		tween.tween_callback(func():
			for mesh_instance in mesh_instances:
				if is_instance_valid(mesh_instance):
					mesh_instance.visible = false
		)

		tween.tween_interval(hidden_duration)

		tween.tween_callback(func():
			for mesh_instance in mesh_instances:
				if is_instance_valid(mesh_instance):
					mesh_instance.visible = true
		)

		for override in overrides:
			tween.parallel().tween_property(override, "albedo_color:a", 1.0, fade_in_duration)

		tween.tween_callback(func():
			for mesh_instance in mesh_instances:
				if is_instance_valid(mesh_instance):
					mesh_instance.material_override = null
		)

	await get_tree().create_timer(fade_out_duration + hidden_duration).timeout
	particles.stop()


## Klebt object an denselben Slot wie die aktuelle Unterseite des Würfels
## (visuell also direkt an die Würfelfläche). Die Seite wird dadurch
## inaktiv: sie wird nicht mehr (de)aktiviert, bis sie wieder Bodenkontakt
## hat und das Objekt zurück auf den Boden gegeben wird.
func glue_to_bottom_face(object: Node3D) -> void:
	var slot := _bottom_slot()
	if slot == null or slot.get_child_count() == 0:
		return

	GameManager.unregister_entity(object)
	object.get_parent().remove_child(object)
	slot.add_child(object)
	# Slot-Y zeigt von der Würfelmitte weg (Flächennormale) - leicht
	# davor versetzen, damit die Spur nicht mit der Face-Mesh z-fighted.
	object.position = Vector3.UP * 0.1
	object.rotation = Vector3.ZERO
	# Kein extra "glue"-Aufruf nötig: BaseFace.is_disabled() erkennt das
	# angehängte Objekt rein strukturell über den zweiten Slot-Kindknoten.


func _release_glued_object(face: BaseFace) -> void:
	var object := face.get_attached_payload()
	if object == null:
		return

	object.get_parent().remove_child(object)
	get_tree().current_scene.add_child(object)
	object.global_position = Vector3(global_position.x, 0, global_position.z)
	GameManager.register_entity(object)
	GameManager.ignore_next_pickup(object)


## Sucht den Slot mit der aktuell höchsten (want_max=true) bzw.
## niedrigsten (want_max=false) Welt-Y-Position - also den Slot, der gerade
## oben bzw. unten am Würfel liegt. Gemeinsame Grundlage für
## _bottom_slot()/get_top_face_module(), damit die Min/Max-Suche nicht
## doppelt gepflegt werden muss.
func _extreme_slot(want_max: bool) -> Marker3D:
	var found : Marker3D = null
	var best := -INF if want_max else INF

	for slot_name in slots:
		var marker : Marker3D = slots[slot_name]
		var y := marker.global_position.y
		if (want_max and y > best) or (not want_max and y < best):
			best = y
			found = marker

	return found


func _bottom_slot() -> Marker3D:
	return _extreme_slot(false)


## Die aktuell obenliegende Würfelseite (oder null bei leerem Slot).
func get_top_face_module() -> BaseFace:
	var top_slot := _extreme_slot(true)
	if top_slot and top_slot.get_child_count() > 0:
		return top_slot.get_child(0)
	return null


## Die aktuell untenliegende Würfelseite (oder null bei leerem Slot).
func get_bottom_face_module() -> BaseFace:
	var slot := _bottom_slot()
	if slot and slot.get_child_count() > 0:
		return slot.get_child(0)
	return null


## Sucht den Slot, der aktuell am stärksten entgegen der Roll-Richtung
## ausgerichtet ist (= die Seite, die nach dem Rollen oben liegt).
func get_next_top_face(direction: Vector3) -> BaseFace:
	var target_dir = -direction.normalized()
	var found = null
	var best_match = -9999.0

	for slot_name in slots:
		var marker : Marker3D = slots[slot_name]
		var marker_dir = marker.global_transform.basis.y
		var dot = marker_dir.dot(target_dir)

		if dot > best_match:
			best_match = dot
			found = marker

	if found and found.get_child_count() > 0:
		return found.get_child(0)

	return null

## Deckbuilding-Schnittstelle: tauscht die Szene im aktuell untenliegenden
## Slot gegen new_scene aus und gibt die verdrängte Szene zurück (z.B. eine
## Basis-Seite mit Würfelaugen oder eine ersetzte Fähigkeit), damit sie als
## neues Pickup auf dem Feld platziert werden kann.
func attach_to_bottom(new_scene: PackedScene) -> PackedScene:
	var slot := _bottom_slot()
	if slot == null:
		return null

	var displaced_scene : PackedScene = null
	if slot.get_child_count() > 0:
		var old_face : BaseFace = slot.get_child(0)
		displaced_scene = old_face.source_scene

	slot_scene(slot, new_scene)
	return displaced_scene


## Setzt eine (neue) Face-Szene in einen Slot ein; eine dort bereits
## vorhandene Seite wird ersetzt.
func slot_scene(slot: Marker3D, scene: PackedScene) -> void:
	# remove_child() VOR queue_free(): queue_free() allein löscht erst am
	# Frame-Ende, der Slot hätte also kurzzeitig zwei Kinder und
	# get_top_face_module()/get_bottom_face_module() (die schlicht
	# get_child(0) zurückgeben) würden in diesem Frame noch die alte statt
	# der neuen Seite liefern.
	for child in slot.get_children():
		slot.remove_child(child)
		child.queue_free()

	var new_scene_instance = scene.instantiate()
	slot.add_child(new_scene_instance)

	if new_scene_instance is BaseFace:
		new_scene_instance.source_scene = scene
		new_scene_instance.owner_player = self
