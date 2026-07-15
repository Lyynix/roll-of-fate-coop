class_name BaseFace
extends Node3D

## Optionaler AnimationPlayer der konkreten Face-Szene ("Activate"-Animation,
## siehe pre_activate()/deactivate()). get_node_or_null statt $: die einfachen
## Zahlenseiten haben keinen AnimationPlayer, ein harter $-Zugriff würde dort
## bei jeder Instanziierung einen (folgenlosen) Fehler ins Log schreiben.
@onready var anim_player: AnimationPlayer = get_node_or_null("AnimationPlayer")

## Die PackedScene, aus der diese Seite instanziert wurde - wird für
## Player.attach_to_bottom() benötigt, um eine verdrängte Seite wieder als
## Pickup auf das Feld legen zu können. Für Start-Seiten direkt in der Szene
## gesetzt, für später angebrachte Seiten von slot_scene() befüllt.
@export var source_scene: PackedScene = null

## Die Player-Instanz, an der diese Seite gerade angebracht ist - gesetzt von
## Player.slot_scene(). Fähigkeiten, die "den Spieler" brauchen (Turret,
## Flammenwerfer, Holo-Schild), müssen darüber gehen statt über
## GameManager.player: dieselbe Face-Szene kann sowohl an der lokal
## gesteuerten Kugel als auch am Koop-Puppet des anderen Spielers hängen, und
## GameManager.player wäre in letzterem Fall schlicht die falsche Instanz.
var owner_player: Player = null

func pre_activate():
	if anim_player and anim_player.has_animation("Activate"):
		anim_player.play("Activate", -1, 2)

func activate():
	pass

func deactivate():
	if anim_player and anim_player.has_animation("Activate"):
		anim_player.play("Activate", -1, -2, true)

func post_deactivate():
	pass


## Erlaubt es der aktuell aktiven (obenliegenden) Seite, die normale
## Roll-Bewegung komplett zu übersteuern (z.B. Phase, Dash). Wird vor dem
## eigentlichen Rollen aufgerufen. Gibt true zurück, wenn die Eingabe
## vollständig selbst behandelt wurde (normales Rollen entfällt dann).
func modify_roll(_player: Player, _direction: Vector3) -> bool:
	return false


## Ob diese Seite aktuell durch eine angeklebte Schleimspur blockiert ist
## und deshalb nicht (de)aktiviert werden darf - strukturell erkannt: am
## selben Slot hängt noch ein zweites Kind außer mir selbst (egal ob durch
## normales Überrollen einer Spur oder die Slime-Falle, die alle 6 Seiten
## auf einmal beklebt, siehe Player.glue_all_faces()). Kein separates Flag
## nötig, der Verklebungs-Zustand kann so nie auseinanderlaufen.
func is_disabled() -> bool:
	return get_attached_payload() != null


## Gibt das an meinem Slot angebrachte Objekt zurück (z.B. eine
## Schleimspur), oder null wenn keins angebracht ist.
func get_attached_payload() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child != self:
			return child
	return null


## Liefert alle als Partikel-/Effekt-Austrittspunkte markierten Node3D-Kinder
## (Name beginnt mit "EmitPoint") - frei in der jeweiligen Face-Szene
## platzierbar (z.B. im Editor verschiebbar oder an ein neues Modell
## angepasst). Die lokale X-Achse einer EmitPoint-Node gibt vor, in welche
## Richtung von dort aus gefeuert/gespawnt wird (siehe TurretFace,
## FlamethrowerFace).
func get_emit_points() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for child in get_children():
		if child is Node3D and child.name.begins_with("EmitPoint"):
			result.append(child)
	return result


## Rundet eine Weltrichtung auf die nächstgelegene Gitter-Achse (X oder Z) -
## EmitPoint-Nodes zeigen im Idealfall exakt entlang einer Achse, kleine
## Abweichungen durch Rotation/Float-Ungenauigkeit werden hier abgefangen.
static func snap_to_cardinal(dir: Vector3) -> Vector3i:
	if absf(dir.x) >= absf(dir.z):
		return Vector3i(signi(roundi(dir.x)), 0, 0)
	return Vector3i(0, 0, signi(roundi(dir.z)))
