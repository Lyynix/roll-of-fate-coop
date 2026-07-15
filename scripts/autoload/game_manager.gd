extends Node
## Zentrale Zustandsmaschine und Autorität für den Rundenablauf (siehe State),
## den globalen Run-Zustand (HP/Score/Etage) und - im Koop - für die
## host-autoritative Synchronisation (Nachrichten-Dispatcher, Gegner-Snapshots).
## Entities treiben die Zustandsmaschine nie direkt an, sondern melden nur
## Ereignisse (z.B. Player -> on_player_turn_ended()).

enum State {
	PLAYER_TURN,
	SECONDARY_TURN,
	RESOLVING,
	ENEMY_TURN,
	GAME_OVER,
	LEVEL_COMPLETE
}
var current_state: State


signal state_changed(new_state: State)
signal player_turn_started          # Player darf swipen
signal secondary_turn_started       # Koop: der Secondary-Spieler darf swipen
signal enemies_turn_started         # Enemies werden durchiteriert
signal player_hp_changed(current: int, max_hp: int)
signal floor_changed(floor: int)
signal score_changed(score: int)
signal highscore_changed(highscore: int)
signal game_started                 # Bei jedem start_game() (Neues Spiel UND Neustart)
signal level_received(data: Dictionary)  # Koop: level_data-Nachricht vom Host eingetroffen


var current_floor: int = 1
var player_hp: int = 2
var max_player_hp: int = 2
var score: int = 0
## Höchster je erreichter Score - wird von MainMenu geladen/persistiert
## (siehe settings.cfg), hier nur der Laufzeit-Wert + die Aktualisierungslogik.
var highscore: int = 0

## Ob bereits ein Run gestartet wurde (seit App-Start) - steuert den
## "Fortsetzen"-Button im Hauptmenü (siehe MainMenu.gd).
var has_active_game: bool = false


var player: Node3D = null
## Koop: die per Netzwerk nachgespielte Darstellung des jeweils anderen
## Spielers auf diesem Bildschirm. Bleibt null außerhalb Koop.
var remote_player: Node3D = null
var enemies: Array[BaseEnemy] = []
var entities: Array[BaseEntity] = []
var level_parent: Node3D = null
var _ignore_pickup_entity: BaseEntity = null
var player_shielded: bool = false

const PREDICTION_SCENE: PackedScene = preload("res://scenes/map_elements/danger_tile.tscn")
const PLAYER_SCENE: PackedScene = preload("res://scenes/entities/player.tscn")

## Koop: wer hat je ein Ziel-Feld erreicht (zwei gleichwertige, unzugeordnete
## Ziel-Felder pro Etage, siehe LevelGenerator) - Level erst komplett wenn
## beide true sind. Werden pro Etage zurückgesetzt.
var _host_reached_exit: bool = false
var _secondary_reached_exit: bool = false

## Zwischenspeicher zwischen _finish_turn() und _resolve(), da change_state()
## keine Zusatzdaten an seine Handler durchreicht (siehe _resolve()).
var _resolving_actor: Node3D = null
var _resolving_next_state: State = State.ENEMY_TURN

## Ob gerade eine Koop-Partie läuft (Puppet gespawnt) - steuert, ob ein
## Verbindungsabbruch die Szene hart neu lädt (siehe _on_network_disconnected()).
var _coop_run_active: bool = false

## Koop: laufender Zähler für BaseEnemy.sync_id, siehe register_enemy().
var _next_sync_id: int = 0

## Koop: Typ-String -> Szene für den Gegner-Zug-Sync (siehe _build_enemy_turn_result()/
## _handle_enemy_turn_result()) - anders als LevelManager.ENEMY_SCENES (nur die beim
## Level-Spawn gezogenen Typen, nach Index) auch für zur Laufzeit entstehende Gegner
## wie Bomber-Bomben, über einen stabilen Namen statt eines Index.
const SYNCED_ENEMY_SCENES := {
	"slime": preload("res://scenes/entities/slime.tscn"),
	"sniper": preload("res://scenes/entities/sniper.tscn"),
	"bully": preload("res://scenes/entities/bully.tscn"),
	"bomber": preload("res://scenes/entities/bomber.tscn"),
	"bomb": preload("res://scenes/map_elements/bomb.tscn"),
}


func _ready() -> void:
	NetworkManager.message_received.connect(_on_message_received)
	NetworkManager.disconnected.connect(_on_network_disconnected)


func change_state(new_state: State) -> void:
	current_state = new_state
	state_changed.emit(new_state)
	print("[GameManager] State → ", State.keys()[new_state])

	# Nur der Host entscheidet wirklich über Zustandsübergänge - der Secondary
	# übernimmt current_state ausschließlich über eingehende state_sync-
	# Nachrichten (siehe _handle_state_sync()), niemals durch eigene Logik.
	if NetworkManager.role == NetworkManager.Role.HOST:
		NetworkManager.send({"type": "state_sync", "state": new_state})

	match new_state:
		State.PLAYER_TURN:
			_begin_player_turn()
		State.SECONDARY_TURN:
			_begin_secondary_turn()
		State.RESOLVING:
			_resolve()
		State.ENEMY_TURN:
			_begin_enemy_turn()
		State.GAME_OVER:
			_handle_game_over()
		State.LEVEL_COMPLETE:
			_handle_level_complete()


func _begin_player_turn() -> void:
	# .duplicate(): show_prediction() läuft hier zwar normalerweise ohne
	# Seiteneffekte auf die Gegner-Liste, aber wir iterieren grundsätzlich
	# nie über die Live-Referenz von `enemies` (siehe Kommentar in
	# _begin_enemy_turn() für den konkreten Grund).
	for enemy in enemies.duplicate():
		if is_instance_valid(enemy):
			enemy.show_prediction()
	player_turn_started.emit()


func _begin_secondary_turn() -> void:
	secondary_turn_started.emit()


## Läuft nur auf dem Host (bzw. im Singleplayer) wirklich - auf dem Secondary
## wird diese Methode zwar über eine eingehende state_sync-Nachricht ebenfalls
## über change_state() erreicht, dann aber sofort verlassen: die HP-/Score-/
## Ziel-Auflösung ist bereits vom Host entschieden und kommt separat über
## turn_action/enemy_turn_result an (siehe _handle_turn_action()).
func _resolve() -> void:
	if NetworkManager.role == NetworkManager.Role.SECONDARY:
		return

	var acting_player := _resolving_actor
	var next_state := _resolving_next_state

	if _check_level_exit(acting_player):
		_mark_exit_reached(acting_player)

	_check_pickups(acting_player)
	_check_slime_traps(acting_player)

	if player_hp <= 0:
		change_state(State.GAME_OVER)
		return

	if _all_exits_reached():
		change_state(State.LEVEL_COMPLETE)
		return

	change_state(next_state)


## Läuft nur auf dem Host (bzw. Singleplayer) wirklich - siehe Kommentar bei
## _resolve(), gleiches Prinzip.
func _begin_enemy_turn() -> void:
	if NetworkManager.role == NetworkManager.Role.SECONDARY:
		return

	enemies_turn_started.emit()

	for enemy in enemies.duplicate():
		if is_instance_valid(enemy):
			enemy.hide_prediction()

	# Für Schleimspuren: Position VOR dem eigentlichen Zug merken (die Spur
	# entsteht an der ALTEN Position, siehe Slime.spawn_trace()) - wird
	# unten (nur bei Slimes) mit relayt, siehe _build_enemy_turn_result().
	var enemies_before := enemies.duplicate()
	var pos_before_by_enemy := {}
	for enemy in enemies_before:
		if is_instance_valid(enemy):
			pos_before_by_enemy[enemy] = Vector3i(enemy.global_position)

	# Wichtig: über eine Kopie iterieren, NICHT über `enemies` selbst!
	# enemy.take_turn() kann dazu führen, dass sich der Gegner selbst (oder
	# ein anderer, z.B. eine Bombe die Nachbarn im Explosionsradius tötet)
	# per die()/unregister_enemy() aus `enemies` entfernt. Würde man über
	# die Live-Referenz iterieren, verschieben sich dabei die Indizes der
	# noch folgenden Gegner nach vorne, und der Index-Cursor der for-Schleife
	# würde den jeweils nächsten Gegner überspringen - der bekäme diese
	# Runde dann fälschlich keinen Zug.
	for enemy in enemies_before:
		if not is_instance_valid(enemy):
			continue
		await enemy.take_turn()

	# Das Holo-Schild schützt nur für genau diesen einen Gegner-Zug.
	player_shielded = false

	if NetworkManager.is_networked():
		NetworkManager.send(_build_enemy_turn_result(pos_before_by_enemy))

	# Nach allen Gegnern: Ist der Spieler jetzt tot?
	if player_hp <= 0:
		change_state(State.GAME_OVER)
		return

	# Nächste Runde
	change_state(State.PLAYER_TURN)


## Baut einen VOLLSTÄNDIGEN Schnappschuss des Gegner-/Spieler-Zustands nach
## einem Gegner-Zug - bewusst kein reines Bewegungs-Diff mehr, weil ein
## einzelner Gegner-Zug beliebig viele Nebenwirkungen haben kann, die eine
## Bewegungsliste nicht abdeckt: Bomber lässt eine komplett neue Bombe
## fallen, eine Bombe kann nicht gerade an der Reihe befindliche
## Nachbar-Gegner mit-töten, Bully schiebt den Spieler mit sich, Slime
## hinterlässt eine Spur. Ein vollständiger Abgleich über sync_id (statt
## Array-Index) auf der Empfängerseite (siehe _handle_enemy_turn_result())
## deckt all das ab, ohne jeden Einzelfall gesondert behandeln zu müssen.
func _build_enemy_turn_result(pos_before_by_enemy: Dictionary) -> Dictionary:
	var enemy_states: Array[Dictionary] = []
	for enemy in enemies:
		if not is_instance_valid(enemy) or not (enemy is BaseEnemy):
			continue

		var state := {
			"sync_id": enemy.sync_id,
			"sync_type": _sync_type_for(enemy),
			"pos": Vector3i(enemy.global_position),
			"hp": enemy.hp,
			"cooldown_current": enemy.cooldown_current,
		}
		if enemy is Slime:
			state["next_move"] = enemy.next_move
			if pos_before_by_enemy.has(enemy):
				state["trace_at"] = pos_before_by_enemy[enemy]
		if enemy is Bomb:
			state["ticks_remaining"] = enemy.ticks_remaining
		if enemy is Sniper:
			state["fired"] = enemy.consume_just_fired()

		enemy_states.append(state)

	return {
		"type": "enemy_turn_result",
		"hp": player_hp,
		"score": score,
		"player_shielded": player_shielded,
		"host_pos": Vector3i(player.global_position) if player != null else Vector3i.ZERO,
		"secondary_pos": Vector3i(remote_player.global_position) if remote_player != null else Vector3i.ZERO,
		"enemies": enemy_states,
	}


func _sync_type_for(enemy: BaseEnemy) -> String:
	if enemy is Slime: return "slime"
	if enemy is Sniper: return "sniper"
	if enemy is Bully: return "bully"
	if enemy is Bomber: return "bomber"
	if enemy is Bomb: return "bomb"
	return ""


# ── End States ──

func _handle_game_over() -> void:
	print("[GameManager] GAME OVER auf Etage ", current_floor)
	SoundManager.play_sfx("game_over")

func _handle_level_complete() -> void:
	add_score(200)
	SoundManager.play_sfx("next_level")
	print("[GameManager] Etage ", current_floor, " abgeschlossen!")

	await _animate_level_exit()

	current_floor += 1
	floor_changed.emit(current_floor)
	_host_reached_exit = false
	_secondary_reached_exit = false
	await _sync_level(current_floor)
	_move_player_to_start()

	await _animate_level_enter()

	change_state(State.PLAYER_TURN)


## Hebt den/die Würfel aus der alten Etage heraus (y: 0 → 0.5), bevor die
## neue Etage generiert wird - als würden sie ins nächste Level "aufsteigen".
## Animiert im Koop beide Würfel (eigene Kugel + Puppet) parallel.
func _animate_level_exit() -> void:
	var targets := get_players()
	if targets.is_empty():
		return
	var tween := create_tween().set_parallel(true)
	for p in targets:
		tween.tween_property(p, "global_position:y", 0.5, 0.35)
	await tween.finished


## Lässt den/die Würfel von unten (y: -0.5 → 0) in die neu generierte Etage
## "aufsteigen" - Gegenstück zu _animate_level_exit().
func _animate_level_enter() -> void:
	var targets := get_players()
	if targets.is_empty():
		return
	for p in targets:
		p.global_position.y = -0.5
	var tween := create_tween().set_parallel(true)
	for p in targets:
		tween.tween_property(p, "global_position:y", 0.0, 0.35)
	await tween.finished


func _move_player_to_start() -> void:
	if player != null:
		var target := LevelManager.start_position
		if NetworkManager.role == NetworkManager.Role.SECONDARY:
			target = LevelManager.secondary_start_position
		player.global_position = LevelManager.grid_to_world(target)

	if remote_player != null:
		var remote_target := LevelManager.secondary_start_position
		if NetworkManager.role == NetworkManager.Role.SECONDARY:
			remote_target = LevelManager.start_position
		remote_player.global_position = LevelManager.grid_to_world(remote_target)


## Generiert die Etage lokal (Host bzw. Singleplayer) und verschickt sie bei
## aktiver Koop-Verbindung an den Secondary - oder wartet umgekehrt
## (Secondary) auf genau diese Nachricht vom Host, statt selbst zu
## generieren. Verhindert RNG-Divergenz zwischen den Geräten (siehe
## LevelManager.serialize_level()/apply_remote_level()). level_received wird
## vom zentralen Nachrichten-Dispatcher (_on_message_received()) ausgelöst,
## nicht mehr direkt vom rohen NetworkManager-Signal - robust dagegen, dass
## inzwischen weitere Nachrichtentypen über dieselbe Verbindung laufen.
func _sync_level(floor_number: int) -> void:
	if NetworkManager.role == NetworkManager.Role.SECONDARY:
		var data: Dictionary = await level_received
		LevelManager.apply_remote_level(data, level_parent)
	else:
		LevelManager.generate_level(floor_number, level_parent)
		if NetworkManager.is_networked():
			NetworkManager.send(LevelManager.serialize_level())


## Spawnt einmalig die zweite, per Netzwerk nachgespielte Würfel-Instanz
## (siehe Player.is_remote_puppet) - nur in Koop, nur wenn noch keine da ist.
## Positionierung übernimmt der nachfolgende _move_player_to_start()-Aufruf.
func _ensure_remote_player_spawned() -> void:
	if not NetworkManager.is_networked() or remote_player != null:
		return
	_coop_run_active = true
	var puppet := PLAYER_SCENE.instantiate()
	puppet.is_remote_puppet = true
	level_parent.add_child(puppet)


## Verbindungsabbruch mitten in einer laufenden Koop-Partie: harter
## Szenen-Reload statt zu versuchen, hängende await-Aufrufe sauber
## abzubrechen - ein await auf ein Signal, das nie kommt, hängt in GDScript
## ohne Timeout für immer. Ein Reload verwirft alle offenen Coroutinen
## zusammen mit den Knoten, an denen sie hängen. Deckt sich mit der bereits
## getroffenen Entscheidung "Verbindungsabbruch → zurück ins Menü, kein
## Reconnect". Nur relevant, wenn überhaupt schon eine Koop-Partie lief -
## sonst kümmert sich bereits MainMenu._on_network_disconnected() (Abbruch
## während der Lobby-Suche) darum.
func _on_network_disconnected() -> void:
	if not _coop_run_active:
		return
	_coop_run_active = false
	remote_player = null
	get_tree().reload_current_scene()


# ══════════════════════════════════════════
#  Nachrichten-Dispatcher (Koop)
# ══════════════════════════════════════════

func _on_message_received(data: Dictionary) -> void:
	match data.get("type"):
		"level_data":
			level_received.emit(data)
		"turn_request":
			_handle_turn_request(data)
		"turn_rejected":
			_handle_turn_rejected()
		"turn_action":
			_handle_turn_action(data)
		"enemy_turn_result":
			_handle_enemy_turn_result(data)
		"state_sync":
			_handle_state_sync(data)


## Host: prüft+wendet Secondarys Zugwunsch auf dessen Puppet (remote_player)
## an. Bei Erfolg löst roll() intern bereits turn_ended/on_player_turn_ended()
## aus - das übernimmt Auflösung + turn_action/state_sync-Versand vollständig
## (siehe on_player_turn_ended()/_finish_turn()), hier ist dafür nichts
## weiter nötig. Bei Ablehnung (Wand/Gegner im Weg) kommt turn_rejected
## zurück, sonst würde ein ungültiger Tipp das Spiel sonst stumm einfrieren.
func _handle_turn_request(data: Dictionary) -> void:
	if current_state != State.SECONDARY_TURN or remote_player == null:
		NetworkManager.send({"type": "turn_rejected"})
		return

	var direction: Vector3 = data["direction"]
	var accepted: bool = await remote_player.roll(direction, remote_player.roll_speed, true)
	if not accepted:
		NetworkManager.send({"type": "turn_rejected"})


func _handle_turn_rejected() -> void:
	if player != null:
		player.awaiting_input = true


## Secondary: spielt eine vom Host bestätigte Aktion nach - auf der eigenen
## Kugel (actor "secondary", die eigene Anfrage wurde bestätigt) oder auf dem
## Puppet (actor "host", Hosts eigener Zug). bypass_awaiting_input=true, da
## roll() sonst auf der eigenen Kugel ablehnen würde (awaiting_input steht
## seit dem Abschicken der Anfrage auf false) und das Puppet nie eigene
## Eingaben bekommt.
func _handle_turn_action(data: Dictionary) -> void:
	var direction: Vector3 = data["direction"]
	var acting: Node3D = player if data["actor"] == "secondary" else remote_player
	if acting != null:
		await acting.roll(direction, acting.roll_speed, true)

	player_hp = data["hp"]
	score = data["score"]
	player_shielded = data["player_shielded"]
	player_hp_changed.emit(player_hp, max_player_hp)
	score_changed.emit(score)


## Secondary: gleicht den eigenen Gegner-Bestand VOLLSTÄNDIG an den vom Host
## gesendeten Schnappschuss an (siehe _build_enemy_turn_result()) - über
## sync_id statt Array-Index, damit auch zur Laufzeit neu entstandene (z.B.
## Bomber-Bomben) oder außerplanmäßig (z.B. durch eine Bomben-Explosion)
## gestorbene Gegner korrekt ankommen. Keine eigene Gegner-KI-Entscheidung,
## reines Nachbauen/Nachspielen.
func _handle_enemy_turn_result(data: Dictionary) -> void:
	var by_sync_id := {}
	for enemy in enemies:
		if is_instance_valid(enemy) and enemy is BaseEnemy and enemy.sync_id >= 0:
			by_sync_id[enemy.sync_id] = enemy

	var seen_ids := {}
	for enemy_data in data["enemies"]:
		var sync_id: int = enemy_data["sync_id"]
		seen_ids[sync_id] = true

		var enemy: BaseEnemy = by_sync_id.get(sync_id)
		if enemy == null:
			# Neu entstanden (z.B. eine von Bomber fallengelassene Bombe) -
			# frisch nachbauen statt zu bewegen. sync_id MUSS vor add_child()
			# gesetzt werden - register_enemy() (ausgelöst durch _ready())
			# würde sonst automatisch eine eigene, falsche ID vergeben
			# (gleiches Muster wie is_remote_puppet beim Koop-Puppet).
			var scene: PackedScene = SYNCED_ENEMY_SCENES.get(enemy_data.get("sync_type", ""))
			if scene == null:
				continue
			enemy = scene.instantiate()
			enemy.sync_id = sync_id
			level_parent.add_child(enemy)
			enemy.global_position = Vector3(enemy_data["pos"])
		else:
			await enemy.move_to_grid(enemy_data["pos"])

		enemy.hp = enemy_data["hp"]
		enemy.cooldown_current = enemy_data["cooldown_current"]

		if enemy is Slime:
			if enemy_data.has("trace_at"):
				enemy.spawn_trace(enemy_data["trace_at"])
			enemy.next_move = enemy_data.get("next_move", Vector3i.ZERO)

		if enemy is Bomb:
			enemy.ticks_remaining = enemy_data.get("ticks_remaining", 0)

		if enemy is Sniper and enemy_data.get("fired", false):
			# _current_aim_target ist zu diesem Zeitpunkt bereits korrekt
			# gesetzt (siehe Sniper._update_barrel(), läuft unabhängig vom
			# Netzwerk jeden Frame) - seit dem Schuss hat sich noch kein
			# Spieler bewegt, die Zugfolge ist strikt sequenziell.
			enemy.play_shot_effect()

	# Alles was lokal noch existiert, aber nicht mehr in der Liste vorkam,
	# ist auf dem Host gestorben - unabhängig wodurch (eigener Zug, eine
	# Bomben-Explosion im selben Gegner-Zug, ...). Deckt damit automatisch
	# auch "Tod mitten in der Zugschleife" ab, ohne den Fall extra zu behandeln.
	for sync_id in by_sync_id:
		if not seen_ids.has(sync_id):
			var enemy: BaseEnemy = by_sync_id[sync_id]
			if is_instance_valid(enemy) and not enemy.is_dead:
				enemy.die()

	_sync_player_position(remote_player, data["host_pos"])
	_sync_player_position(player, data["secondary_pos"])

	player_hp = data["hp"]
	score = data["score"]
	player_shielded = data["player_shielded"]
	player_hp_changed.emit(player_hp, max_player_hp)
	score_changed.emit(score)


## Sicherheitsnetz für Spieler-Positionsänderungen durch Gegner-Nebenwirkungen
## (z.B. Bully schiebt den Spieler beim Rammen mit sich) - wird bei jedem
## Gegner-Zug-Ergebnis mitgeschickt (nicht nur wenn sich wirklich was
## geändert hat, einfacher als das vorab zu erkennen) und ist im Normalfall
## ein no-op, da die Position schon durch die deterministische Zug-Wiedergabe
## stimmt.
func _sync_player_position(p: Node3D, target: Vector3i) -> void:
	if p == null or Vector3i(p.global_position) == target:
		return
	var tween := create_tween()
	tween.tween_property(p, "global_position", Vector3(target), 0.3)


## Secondary: übernimmt current_state 1:1 vom Host über denselben
## change_state()-Dispatch wie der Host selbst - _resolve()/_begin_enemy_turn()
## erkennen intern (Rolle == SECONDARY) dass sie hier nichts wirklich
## auflösen/entscheiden dürfen und kehren sofort zurück; die rein visuellen
## Handler (_begin_player_turn()/_begin_secondary_turn()/_handle_level_complete())
## laufen dagegen ganz normal (Vorschau-Marker zeigen, Etage synchronisieren usw.).
func _handle_state_sync(data: Dictionary) -> void:
	change_state(data["state"])


# ══════════════════════════════════════════
#  CHECKS
# ══════════════════════════════════════════

func _check_level_exit(acting_player: Node3D) -> bool:
	if acting_player == null:
		return false
	var grid_pos := LevelManager.world_to_grid(acting_player.global_position)
	var cell := LevelManager.get_cell(grid_pos)
	return cell != null and cell.type == GridCell.Type.EXIT


func _mark_exit_reached(acting_player: Node3D) -> void:
	if acting_player == player:
		_host_reached_exit = true
	elif acting_player == remote_player:
		_secondary_reached_exit = true


## Im Singleplayer gibt es zwar (strukturell, siehe LevelGenerator) zwei
## Ziel-Felder, aber nur einen Spieler - das Erreichen irgendeines der beiden
## genügt dort weiterhin sofort, exakt wie vor Schritt 3.
func _all_exits_reached() -> bool:
	if not NetworkManager.is_networked():
		return _host_reached_exit
	return _host_reached_exit and _secondary_reached_exit


func _check_pickups(acting_player: Node3D) -> void:
	if acting_player == null:
		return
	var entity := get_entity_at(Vector3i(acting_player.global_position))
	if entity != null and entity != _ignore_pickup_entity:
		entity.on_player_entered(acting_player)
	_ignore_pickup_entity = null


## Verhindert, dass eine Entity, die soeben erst (z.B. durch das Lösen
## einer geklebten Würfelseite) auf dem aktuellen Feld abgelegt wurde, im
## selben Zug sofort wieder über on_player_entered() aufgenommen wird.
func ignore_next_pickup(entity: BaseEntity) -> void:
	_ignore_pickup_entity = entity


## Strafe fürs Reinrollen ins Prognose-Feld eines Schleim-Würfels: alle
## Würfelseiten verkleben, der Schleim-Würfel stirbt.
func _check_slime_traps(acting_player: Node3D) -> void:
	if acting_player == null:
		return

	var player_pos := Vector3i(acting_player.global_position)
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		if enemy is Slime and enemy.predict().has(player_pos):
			(acting_player as Player).glue_all_faces()
			enemy.die()
			return


# ══════════════════════════════════════════
#  PUBLIC API – von anderen Systemen aufgerufen
# ══════════════════════════════════════════

## Vom Player aufgerufen wenn Roll + Ability komplett fertig sind. Auf dem
## Secondary-Gerät strukturell wirkungslos (siehe Guard) - dort entscheidet
## nie lokal ausgeführter Code (weder die eigene Kugel noch das Puppet, siehe
## Player.roll()) über den nächsten Zustand, das passiert ausschließlich über
## state_sync/turn_action vom Host (siehe _handle_state_sync()/_handle_turn_action()).
func on_player_turn_ended(direction: Vector3) -> void:
	if NetworkManager.role == NetworkManager.Role.SECONDARY:
		return

	match current_state:
		State.PLAYER_TURN:
			_finish_turn(player, direction, State.SECONDARY_TURN if NetworkManager.is_networked() else State.ENEMY_TURN)
		State.SECONDARY_TURN:
			_finish_turn(remote_player, direction, State.ENEMY_TURN)
		_:
			push_warning("[GameManager] on_player_turn_ended() im falschen State!")


func _finish_turn(acting_player: Node3D, direction: Vector3, next_state: State) -> void:
	_resolving_actor = acting_player
	_resolving_next_state = next_state
	change_state(State.RESOLVING)

	if NetworkManager.is_networked():
		NetworkManager.send({
			"type": "turn_action",
			"actor": "host" if acting_player == player else "secondary",
			"direction": direction,
			"hp": player_hp,
			"score": score,
			"player_shielded": player_shielded,
		})


## Schadens-Schnittstelle
func damage_player(amount: int) -> void:
	if player_shielded:
		print("[GameManager] Schaden durch Holo-Schild geblockt (", amount, ")")
		return

	player_hp -= amount
	add_score(-10)
	SoundManager.play_sfx("player_damage")
	print("[GameManager] Player HP: ", player_hp, "/", max_player_hp)
	player_hp_changed.emit(player_hp, max_player_hp)


## Heilungs-Schnittstelle: wird von BaseEnemy.take_damage() bei einem
## "echten" Kill (über Schaden, z.B. Turret/Flammenwerfer/Dash) ausgelöst -
## NICHT bei der Slime-Falle, die Gegner direkt über die()/ohne Schaden
## tötet (siehe Player.roll()/_check_slime_traps()).
func heal_player(amount: int) -> void:
	player_hp = mini(player_hp + amount, max_player_hp)
	print("[GameManager] Player HP: ", player_hp, "/", max_player_hp)
	player_hp_changed.emit(player_hp, max_player_hp)


## Aktiviert das Holo-Schild für den kommenden Gegner-Zug.
func activate_shield() -> void:
	player_shielded = true


## Punkte-Schnittstelle. 200 für Level-Abschluss, 30 für einen "echten" Kill
## über Schaden (siehe BaseEnemy.take_damage()), -10 bei erlittenem Schaden.
## Die Slime-Falle (Rammen) tötet direkt über die() statt take_damage() und
## gibt deshalb bewusst keine Punkte (siehe Kommentar dort).
func add_score(points: int) -> void:
	score = maxi(0, score + points)
	score_changed.emit(score)

	if score > highscore:
		highscore = score
		highscore_changed.emit(highscore)


## Registrierung
func register_player(p: Node3D) -> void:
	player = p
	print("[GameManager] Player registriert")
	p.roll_started.connect(LevelManager.trigger_wave)

	change_state(State.PLAYER_TURN)

## Koop: die per Netzwerk nachgespielte Darstellung des anderen Spielers -
## bewusst KEINE Zustandsänderung (anders als register_player()), sonst würde
## das Spawnen des Puppets mitten in einer laufenden Partie den Spielzustand
## zurücksetzen.
func register_remote_player(p: Node3D) -> void:
	remote_player = p
	print("[GameManager] Remote-Player (Puppet) registriert")
	p.roll_started.connect(LevelManager.trigger_wave)


## Vergibt sync_id nur, wenn noch keine gesetzt ist (Normalfall: Level-Spawn,
## siehe LevelManager._spawn_entities_from_data() - Host und Secondary
## durchlaufen dort dieselbe Spawn-Liste in identischer Reihenfolge und
## vergeben so automatisch identische IDs). Ist bereits eine ID gesetzt
## (Secondary baut einen vom Host relayten, zur Laufzeit neu entstandenen
## Gegner nach, siehe _handle_enemy_turn_result() - dort wird sync_id VOR
## add_child() gesetzt), wird nur der Zähler auf dem neuesten Stand
## gehalten, keine neue ID vergeben.
func register_enemy(e: BaseEnemy) -> void:
	if e.sync_id < 0:
		e.sync_id = _next_sync_id
		_next_sync_id += 1
	else:
		_next_sync_id = maxi(_next_sync_id, e.sync_id + 1)
	enemies.append(e)

func unregister_enemy(e: BaseEnemy) -> void:
	enemies.erase(e)


## Alle aktuell registrierten Spieler-Instanzen ([player] im Singleplayer,
## [player, remote_player] in Koop) - Grundlage für nearest_player_to().
func get_players() -> Array:
	var result := []
	if player != null:
		result.append(player)
	if remote_player != null:
		result.append(remote_player)
	return result


## Nächstgelegener Spieler zu pos (Manhattan-Distanz, X/Z-Ebene) - Grundlage
## der Gegner-Zielwahl (siehe enemy.gd/bully.gd/bomber.gd/sniper.gd). Läuft
## für echte Entscheidungen nur auf dem Host (Gegnerzüge sind Host-only,
## siehe _begin_enemy_turn()), degradiert im Singleplayer zu "der eine Spieler".
func nearest_player_to(pos: Vector3) -> Node3D:
	var players := get_players()
	if players.is_empty():
		return null

	var best: Node3D = players[0]
	var best_dist := absf(pos.x - best.global_position.x) + absf(pos.z - best.global_position.z)
	for i in range(1, players.size()):
		var p: Node3D = players[i]
		var dist := absf(pos.x - p.global_position.x) + absf(pos.z - p.global_position.z)
		if dist < best_dist:
			best_dist = dist
			best = p
	return best


## Ob DIESES Gerät gerade an der Reihe ist - für HUD (Vignette) statt einer
## direkten State-Abfrage, da "meine Runde" je nach Rolle einen anderen
## State bedeutet.
func is_my_turn() -> bool:
	if NetworkManager.role == NetworkManager.Role.SECONDARY:
		return current_state == State.SECONDARY_TURN
	return current_state == State.PLAYER_TURN


## Für HUD: kurzer Text, der beschreibt worauf DIESES Gerät gerade wartet -
## leer, wenn es selbst dran ist. Bei RESOLVING (kurzlebiger Übergang
## zwischen zwei Zügen) wird auf den als nächstes anstehenden Zustand
## vorausgeschaut (_resolving_next_state), damit der Text nicht kurz
## fälschlich auf "Gegner zieht" o.ä. umspringt und gleich wieder zurück.
func waiting_reason_text() -> String:
	if is_my_turn():
		return ""

	var effective_state := current_state
	if effective_state == State.RESOLVING:
		effective_state = _resolving_next_state

	if effective_state == State.ENEMY_TURN:
		return "Gegner zieht"
	return "Mitspieler ist dran"


## Gibt die Entity an einer bestimmten Position zurück (oder null)
func get_entity_at(pos: Vector3i) -> BaseEntity:
	for entity in entities:
		if not is_instance_valid(entity):
			continue
		if Vector3i(entity.global_position) == pos:
			return entity
	return null

## Gibt den lebenden Gegner an einer bestimmten Position zurück (oder null)
func get_enemy_at(pos: Vector3i) -> BaseEnemy:
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		if Vector3i(enemy.global_position) == pos:
			return enemy
	return null

func register_entity(e: BaseEntity) -> void:
	entities.append(e)

func unregister_entity(e: BaseEntity) -> void:
	entities.erase(e)



func register_level_parent(parent: Node3D) -> void:
	level_parent = parent


func start_game() -> void:
	has_active_game = true
	current_floor = 1
	player_hp = max_player_hp
	score = 0
	_host_reached_exit = false
	_secondary_reached_exit = false
	floor_changed.emit(current_floor)
	player_hp_changed.emit(player_hp, max_player_hp)
	score_changed.emit(score)
	await _sync_level(current_floor)
	_ensure_remote_player_spawned()
	_move_player_to_start()
	if player and player.has_method("reset_orientation"):
		player.reset_orientation()
	if player and player.has_method("reset_faces"):
		player.reset_faces()
	change_state(State.PLAYER_TURN)
	game_started.emit()
