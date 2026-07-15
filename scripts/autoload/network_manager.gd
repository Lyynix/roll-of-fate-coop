extends Node
## Netzwerk-Fundament des lokalen Koop: WLAN-Discovery (UDP-Broadcast),
## Verbindungsaufbau (TCP) und generischer Nachrichtentransport
## (send()/message_received) - die eigentliche Spiellogik-Synchronisation
## liegt beim GameManager. Bewusst kein Godot-Multiplayer-Framework
## (ENetMultiplayerPeer/RPCs): für eine feste 1:1-Verbindung mit
## host-autoritativer Simulation ist das mehr Overhead als nötig, ein
## einfacher TCPServer/StreamPeerTCP reicht.

signal host_found(ip: String, info: Dictionary)
signal host_lost(ip: String)
signal connected(peer_name: String)
signal disconnected
signal message_received(data: Dictionary)

enum Role { NONE, HOST, SECONDARY }

const DISCOVERY_PORT := 8541
const TCP_PORT := 8542
const ANNOUNCE_INTERVAL := 1.0
## Ein Host, von dem 3s lang kein neues Announce-Paket ankam, gilt als weg
## (z.B. WLAN-Wechsel, App geschlossen) - es gibt kein explizites "Host
## beendet"-Paket, daher rein zeitbasiert.
const HOST_TIMEOUT := 3.0

var role: Role = Role.NONE
## Anzeigename der Gegenseite, erst gültig nach dem "hello"-Handshake (siehe connected-Signal).
var peer_name: String = ""
var local_name: String = generate_default_name()

var _discovery_socket: PacketPeerUDP = null   # Suchender: lauscht auf host_announce-Pakete
var _announce_socket: PacketPeerUDP = null    # Host: sendet die periodischen Broadcasts
var _announce_timer: float = 0.0
var _uptime: float = 0.0

var _tcp_server: TCPServer = null
var _tcp_peer: StreamPeerTCP = null
var _recv_buffer: PackedByteArray = PackedByteArray()
var _hello_sent: bool = false

## IP (String) -> {name, tcp_port, last_seen}
var _known_hosts: Dictionary = {}


func _ready() -> void:
	# Muss auch bei pausiertem SceneTree weiterlaufen (Pause-Menü mitten in
	# einer Koop-Partie darf die TCP-Verbindung nicht einschlafen lassen) -
	# gleiches Muster wie SoundManager/MainMenu.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Best-effort menschenlesbarer Standardname: auf Desktop-Plattformen der
## Rechner-/Benutzername (Umgebungsvariable), sonst ein generischer
## Plattform+Zufalls-Name. Android liefert Sandbox-Apps i.d.R. keine
## brauchbare Umgebungsvariable für einen echten Gerätenamen (dafür bräuchte
## es natives Plugin-Code, nicht mit reinem GDScript machbar) - dort greift
## also meist der Fallback. Auch öffentlich nutzbar als "Zurücksetzen"-Vorschlag
## (siehe MainMenu, wenn der Nutzer den Namen komplett leert).
func generate_default_name() -> String:
	if OS.has_environment("COMPUTERNAME"):
		return OS.get_environment("COMPUTERNAME")
	if OS.has_environment("USER"):
		return OS.get_environment("USER")
	return "%s-%04d" % [OS.get_name(), randi() % 10000]


func is_networked() -> bool:
	return role != Role.NONE


func get_known_hosts() -> Dictionary:
	return _known_hosts


func _process(delta: float) -> void:
	_uptime += delta

	if _discovery_socket != null:
		_poll_discovery()

	if role == Role.HOST:
		_announce_timer -= delta
		if _announce_timer <= 0.0:
			_send_announce()
			_announce_timer = ANNOUNCE_INTERVAL

		if _tcp_server != null and _tcp_peer == null and _tcp_server.is_connection_available():
			_tcp_peer = _tcp_server.take_connection()
			_hello_sent = false

	if _tcp_peer != null:
		_poll_tcp()


# ══════════════════════════════════════════
#  Discovery (UDP)
# ══════════════════════════════════════════

func start_discovery() -> void:
	if _discovery_socket != null:
		return

	_known_hosts.clear()
	_discovery_socket = PacketPeerUDP.new()
	var err := _discovery_socket.bind(DISCOVERY_PORT)
	if err != OK:
		push_warning("[NetworkManager] Discovery-Socket konnte nicht gebunden werden: " + str(err))
		_discovery_socket = null


func stop_discovery() -> void:
	if _discovery_socket != null:
		_discovery_socket.close()
		_discovery_socket = null
	_known_hosts.clear()


func _poll_discovery() -> void:
	while _discovery_socket.get_available_packet_count() > 0:
		var bytes := _discovery_socket.get_packet()
		var ip := _discovery_socket.get_packet_ip()
		var data = bytes_to_var(bytes)
		if not (data is Dictionary) or data.get("type") != "host_announce":
			continue

		var is_new := not _known_hosts.has(ip)
		_known_hosts[ip] = {
			"name": data.get("name", "?"),
			"tcp_port": data.get("tcp_port", TCP_PORT),
			"last_seen": _uptime,
		}
		if is_new:
			host_found.emit(ip, _known_hosts[ip])

	for ip in _known_hosts.keys().duplicate():
		if _uptime - _known_hosts[ip]["last_seen"] > HOST_TIMEOUT:
			_known_hosts.erase(ip)
			host_lost.emit(ip)


func _send_announce() -> void:
	if _announce_socket == null:
		return
	var data := {"type": "host_announce", "name": local_name, "tcp_port": TCP_PORT}
	_announce_socket.put_packet(var_to_bytes(data))


# ══════════════════════════════════════════
#  Verbindungsaufbau (TCP)
# ══════════════════════════════════════════

func start_hosting(display_name: String = "") -> void:
	stop()
	if display_name != "":
		local_name = display_name

	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(TCP_PORT)
	if err != OK:
		push_warning("[NetworkManager] TCP-Server konnte nicht gestartet werden: " + str(err))
		_tcp_server = null
		return

	role = Role.HOST

	_announce_socket = PacketPeerUDP.new()
	_announce_socket.set_broadcast_enabled(true)
	_announce_socket.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_announce_timer = 0.0


## port: vom Host im Announce-Paket mitgeteilter TCP-Port (siehe _known_hosts) -
## aktuell identisch mit TCP_PORT, aber über den Parameter statt einer
## Konstante geführt, falls der Host das später mal abweichend vergibt.
func connect_to_host(ip: String, port: int = TCP_PORT, display_name: String = "") -> void:
	stop_discovery()
	if display_name != "":
		local_name = display_name

	_tcp_peer = StreamPeerTCP.new()
	var err := _tcp_peer.connect_to_host(ip, port)
	if err != OK:
		push_warning("[NetworkManager] Verbindung zu " + ip + " fehlgeschlagen: " + str(err))
		_tcp_peer = null
		return

	role = Role.SECONDARY
	_hello_sent = false
	_recv_buffer.clear()


func _poll_tcp() -> void:
	_tcp_peer.poll()
	var status := _tcp_peer.get_status()

	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		_handle_disconnect()
		return

	if status != StreamPeerTCP.STATUS_CONNECTED:
		return  # noch am Verbindungsaufbau (STATUS_CONNECTING)

	if not _hello_sent:
		_send_message({"type": "hello", "name": local_name})
		_hello_sent = true

	var available := _tcp_peer.get_available_bytes()
	if available > 0:
		var result: Array = _tcp_peer.get_data(available)
		if result[0] == OK:
			_recv_buffer.append_array(result[1])

	_drain_messages()


func _handle_disconnect() -> void:
	var was_networked := is_networked()
	stop()
	if was_networked:
		disconnected.emit()


## TCP ist ein reiner Byte-Strom ohne Nachrichtengrenzen - jede Nachricht
## bekommt einen 4-Byte-Längen-Header vorangestellt (siehe _send_message()),
## damit sie sich hier wieder exakt aus dem Puffer herausschneiden lässt,
## auch wenn mehrere Nachrichten in einem TCP-Paket zusammengefasst ankommen
## oder eine einzelne über mehrere Pakete verteilt eintrifft.
func _drain_messages() -> void:
	while true:
		if _recv_buffer.size() < 4:
			return
		var msg_len := _recv_buffer.decode_u32(0)
		if _recv_buffer.size() < 4 + msg_len:
			return

		var payload := _recv_buffer.slice(4, 4 + msg_len)
		_recv_buffer = _recv_buffer.slice(4 + msg_len)

		var data = bytes_to_var(payload)
		if data is Dictionary:
			_handle_message(data)


func _handle_message(data: Dictionary) -> void:
	# "hello" wird intern behandelt (Handshake), nicht nach außen
	# weitergereicht - die Spiellogik (Level-/Aktions-Sync, siehe GameManager)
	# hängt sich stattdessen an message_received für alle anderen
	# Nachrichtentypen ein.
	if data.get("type") == "hello":
		peer_name = data.get("name", "?")
		connected.emit(peer_name)
		return

	message_received.emit(data)


func _send_message(data: Dictionary) -> void:
	if _tcp_peer == null:
		return
	var payload := var_to_bytes(data)
	var header := PackedByteArray()
	header.resize(4)
	header.encode_u32(0, payload.size())
	_tcp_peer.put_data(header)
	_tcp_peer.put_data(payload)


## Öffentliche Sende-Schnittstelle für die Spiellogik (Level-/Aktions-Sync,
## siehe GameManager/LevelManager).
func send(data: Dictionary) -> void:
	_send_message(data)


# ══════════════════════════════════════════
#  Cleanup
# ══════════════════════════════════════════

## Beendet Discovery, TCP-Verbindung/-Server und setzt die Rolle zurück -
## aufgerufen beim Verlassen des Koop-Panels ohne Verbindung, bei
## disconnected() und vor jedem neuen start_hosting()/connect_to_host(), damit
## nie zwei Sockets/Server gleichzeitig auf denselben Ports hängen.
func stop() -> void:
	stop_discovery()

	if _announce_socket != null:
		_announce_socket.close()
		_announce_socket = null

	if _tcp_peer != null:
		_tcp_peer.disconnect_from_host()
		_tcp_peer = null

	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null

	_recv_buffer.clear()
	_hello_sent = false
	peer_name = ""
	role = Role.NONE
