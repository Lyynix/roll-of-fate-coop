class_name BaseEntity
extends Node3D
## Basisklasse für statische/passive Weltobjekte ohne eigenen Zug (Pickups,
## Schleimspuren, Tiles) mit on_player_entered()-Hook - alles, was einen
## eigenen Zug hat, erbt stattdessen von BaseEnemy.

func _ready() -> void:
	GameManager.register_entity(self)
	_on_ready()

## Überschreibbar für Subklassen-Setup (statt eines _ready-Overrides).
func _on_ready() -> void:
	pass

## Wird aufgerufen wenn ein Spieler auf dieses Feld rollt. entered_player ist
## die konkrete Instanz (im Koop: welcher der beiden Spieler) - Overrides
## müssen darüber gehen statt über GameManager.player, das im Koop nur "die
## lokal gesteuerte Kugel dieses Geräts" meint, nicht zwingend die, die
## gerade tatsächlich auf dem Feld gelandet ist.
func on_player_entered(_entered_player: Node3D) -> void:
	pass

## Entfernt die Entity sauber aus der Welt.
func remove() -> void:
	GameManager.unregister_entity(self)
	await _on_remove()
	queue_free()

## Entfernungs-Animation – optional überschreiben.
func _on_remove() -> void:
	var tween = create_tween()
	tween.tween_property(self, "scale", Vector3.ZERO, 0.2)
	await tween.finished
