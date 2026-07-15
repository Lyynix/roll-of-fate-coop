class_name GhostPlayer
extends Node3D

## Planungs-Vorschau: ein halbtransparentes Duplikat des echten Würfels
## (inklusive aktueller Würfelseiten/Fähigkeiten) das beim Long-Press
## die simulierten Züge vorauszeigt, ohne den echten Spieler zu bewegen.
## Entsteht durch player.pivot.duplicate() - keine separate Modell-Szene.

var _player: Node3D
var _ghost_pos: Vector3i
var _ghost_basis: Basis
var _ghost_pivot: Node3D
var _cube_mesh: Node3D
var _step_tween: Tween
var _path_nodes: Array[Node3D] = []

## Startposition des aktuell animierten Schritts - wird beim Unterbrechen
## als Snap-Ziel genutzt, damit der nächste Schritt von dort aus startet.
var _anim_start_pos: Vector3i

## Schneller als der echte Spieler, damit die Planung nicht ausbremst.
const GHOST_ROLL_SPEED := 9.0


## Erzeugt das Ghost-Duplikat: kopiert den Pivot des Spielers (mit allen
## aktuell eingesetzten Würfelseiten) und macht alle Meshes halbtransparent.
func init(player: Node3D) -> void:
	_player = player
	_ghost_pos = Vector3i(player.global_position)
	_anim_start_pos = _ghost_pos
	_ghost_basis = player.get_node("Pivot/CubeMesh").global_transform.basis

	_ghost_pivot = player.get_node("Pivot").duplicate()
	add_child(_ghost_pivot)

	_cube_mesh = _ghost_pivot.get_node("CubeMesh")

	# Material-Override für jedes Mesh: ersetzt das undurchsichtige Import-
	# Material durch ein einheitlich blaues, halbtransparentes Ghost-Material.
	# transparency = 0.55 allein reicht nicht, weil GLB-Materialien kein
	# Alpha-Blending haben - material_override umgeht das komplett.
	var ghost_mat := StandardMaterial3D.new()
	ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_mat.albedo_color = Color(0.35, 0.65, 1.0, 0.5)

	for mi in _ghost_pivot.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = ghost_mat

	global_position = Vector3(_ghost_pos)
	_reset_pivot_instant()


## Simuliert einen Schritt in direction: wendet Movement-Modifier (Phase,
## Dash) auf die virtuelle Position an, ohne den echten Spieler zu bewegen.
## Gibt true zurück, falls der Ghost sich tatsächlich bewegt hat.
func step(direction: Vector3) -> bool:
	var dir3i := Vector3i(direction.normalized())
	var top_face := _ghost_top_face()

	if top_face != null and not top_face.is_disabled():
		if top_face is PhaseFace:
			return _step_phase(dir3i, direction)
		elif top_face is DashFace:
			return _step_dash(dir3i, direction)

	return _step_walk(dir3i, direction)


func _step_walk(dir3i: Vector3i, dir3: Vector3) -> bool:
	var target := _ghost_pos + dir3i
	if not LevelManager.is_walkable(Vector2i(target.x, target.z)):
		return false
	_do_steps(dir3, 1, 1)
	return true


func _step_phase(dir3i: Vector3i, dir3: Vector3) -> bool:
	# Geht durch Wände/Gegner hindurch, landet aber nie IN einer Wand -
	# dieselbe Distanzwahl wie die echte Bewegung, siehe
	# PhaseFace._furthest_walkable_landing().
	var steps := PhaseFace._furthest_walkable_landing(_ghost_pos, dir3i)
	if steps == 0:
		return false
	# Dreht dabei trotzdem nur EINE Seite weiter, siehe Player.phase_roll().
	_do_steps(dir3, steps, 1)
	return true


func _step_dash(dir3i: Vector3i, dir3: Vector3) -> bool:
	var walkable_steps := 0
	for i in range(1, DashFace.STEPS + 1):
		var candidate := _ghost_pos + dir3i * i
		if not LevelManager.is_walkable(Vector2i(candidate.x, candidate.z)):
			break
		walkable_steps = i
	if walkable_steps == 0:
		return false
	_do_steps(dir3, walkable_steps, walkable_steps)
	return true


## Logikupdate (sofort) + Roll-Animation als Callback-basierter Tween.
## Kein `await` → keine hängenden Coroutines bei Unterbrechung.
## rot_steps: um wie viele Seiten sich der Würfel dabei weiterdreht - bei
## Phase immer 1 unabhängig von der Distanz (siehe Player.phase_roll()),
## sonst gleich steps.
func _do_steps(dir3: Vector3, steps: int, rot_steps: int) -> void:
	var dir3i := Vector3i(dir3.normalized())
	var axis := dir3.cross(Vector3.DOWN).normalized()
	var step_quat := Quaternion(axis, PI / 2)

	for i in range(1, steps + 1):
		_add_path_marker(Vector3(_ghost_pos + dir3i * i) + Vector3.UP * 0.5)

	for _i in range(rot_steps):
		_ghost_basis = (Basis(step_quat) * _ghost_basis).orthonormalized()

	# Startpunkt dieser Animation merken - bei Unterbrechung dorthin snappen
	_anim_start_pos = _ghost_pos
	_ghost_pos += dir3i * steps
	# global_position wird NICHT hier gesetzt - erst wenn die Animation
	# fertig ist (oder beim Unterbrechen auf _anim_start_pos gesetzt).

	_animate_roll(dir3.normalized(), steps, rot_steps)


## Rollt (bzw. gleitet, bei Phase) den Ghost visuell von der aktuellen
## Wurzelposition nach _ghost_pos. Unterbricht eine laufende Animation
## sauber: snapped Wurzel auf _anim_start_pos des unterbrochenen Schritts
## (= dessen logisches Ziel, also der richtige Startpunkt für den nächsten
## Schritt).
func _animate_roll(dir: Vector3, steps: int, rot_steps: int) -> void:
	if _step_tween and _step_tween.is_running():
		_step_tween.kill()
		# Zu dem Ort springen, zu dem der unterbrochene Schritt hätte führen
		# sollen - von dort aus beginnt die neue Animation korrekt.
		global_position = Vector3(_anim_start_pos)
		_reset_pivot_instant()

	var duration := float(steps) / GHOST_ROLL_SPEED
	_step_tween = create_tween()

	if rot_steps == steps:
		# Physisches Rollen: Pivot an die Abrollkante schieben und um
		# steps*90° schwenken (wie Player._perform_roll_step()).
		var pivot_offset := dir * 0.5
		_ghost_pivot.position = pivot_offset
		_cube_mesh.position = Vector3.UP * 0.5 - pivot_offset

		var target_quat := Quaternion(dir.cross(Vector3.DOWN).normalized(),
									PI / 2.0 * steps)
		_step_tween.tween_property(_ghost_pivot, "quaternion", target_quat, duration)
	else:
		# Phase: gleiten statt rollen - Wurzel zur Zielposition schieben und
		# das Mesh parallel um seine Mitte auf die End-Orientierung drehen
		# (spiegelt Player._perform_phase_slide()).
		_step_tween.tween_property(self, "global_position", Vector3(_ghost_pos), duration)
		_step_tween.parallel().tween_property(_cube_mesh, "quaternion",
									_ghost_basis.get_rotation_quaternion(), duration)

	_step_tween.tween_callback(_on_roll_finished)


func _on_roll_finished() -> void:
	global_position = Vector3(_ghost_pos)
	_reset_pivot_instant()


## Setzt Pivot und Cube sofort auf die saubere Ruhehaltung zurück (kein
## Tween) und überträgt _ghost_basis auf das Mesh.
func _reset_pivot_instant() -> void:
	if not is_instance_valid(_ghost_pivot) or not is_instance_valid(_cube_mesh):
		return
	_ghost_pivot.position = Vector3.ZERO
	_ghost_pivot.quaternion = Quaternion.IDENTITY
	_cube_mesh.position = Vector3(0, 0.5, 0)
	_cube_mesh.global_transform.basis = _ghost_basis


## Welcher Slot des echten Würfels läge oben, wenn der Ghost-Würfel mit
## _ghost_basis orientiert ist?
func _ghost_top_face() -> BaseFace:
	var best_y := -INF
	var best_face: BaseFace = null

	for slot_name in _player.slots:
		var marker: Marker3D = _player.slots[slot_name]
		if marker.get_child_count() == 0:
			continue
		var face = marker.get_child(0)
		if not face is BaseFace:
			continue
		var world_y: float = (_ghost_basis * marker.transform.origin).y
		if world_y > best_y:
			best_y = world_y
			best_face = face

	return best_face


func _add_path_marker(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.1
	sphere.height = 0.2
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.85, 0.9, 1.0, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = mat
	mi.mesh = sphere
	get_tree().current_scene.add_child(mi)
	mi.global_position = pos
	_path_nodes.append(mi)


func clear() -> void:
	for node in _path_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_path_nodes.clear()
	queue_free()
