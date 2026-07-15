extends Node

## Zentrale Verwaltung aller Sound-Effekte und der Hintergrundmusik-Playlist.
## SFX laufen über einen kleinen Player-Pool (Round-Robin), damit sich
## überlappende Sounds (z.B. Turret mit mehreren Mündungen) nicht
## gegenseitig abschneiden.

const SFX_POOL_SIZE := 8
## Feste Pfad-Vorlage statt Ordner-Scan: DirAccess.list_dir_begin() ist auf
## gepackten Exports (z.B. Android-APK) unzuverlässig, auch wenn die Datei
## selbst korrekt gebündelt ist. ResourceLoader.exists() auf einem
## bekannten/berechneten Pfad funktioniert dort dagegen zuverlässig - siehe
## Änderung nachdem auf dem Handy nur SFX, aber keine Musik zu hören war.
const MUSIC_PATH_FORMAT := "res://sounds/game_music_%02d.mp3"
const MAX_MUSIC_TRACKS := 20

const SFX_PATHS := {
	"player_move": "res://sounds/player_move.mp3",
	"shot": "res://sounds/shot.mp3",
	"flame": "res://sounds/flame.mp3",
	"shield_activated": "res://sounds/shield_activated.mp3",
	"explosion": "res://sounds/explosion.mp3",
	"kill_enemy": "res://sounds/kill_enemy.mp3",
	"player_damage": "res://sounds/player_damage.mp3",
	"pick_up_face": "res://sounds/pick_up_face.mp3",
	"next_level": "res://sounds/next_level.mp3",
	"game_over": "res://sounds/game_over.mp3",
	"ui_tap": "res://sounds/ui_tap.mp3",
}

var _sfx_streams: Dictionary = {}
var _sfx_players: Array[AudioStreamPlayer] = []
var _next_sfx_player := 0

var _music_player: AudioStreamPlayer
var _music_tracks: Array[AudioStream] = []
var _music_order: Array[int] = []
var _music_index := 0


func _ready() -> void:
	# Musik und UI-Klicks sollen auch weiterlaufen/funktionieren, während das
	# Pause-Menü den Rest des SceneTrees anhält (siehe MainMenu.open()).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_sfx()
	_setup_sfx_pool()
	_setup_music_player()
	_load_music_tracks()
	_play_next_track()


func _load_sfx() -> void:
	for key in SFX_PATHS:
		var stream := load(SFX_PATHS[key]) as AudioStream
		if stream != null:
			_sfx_streams[key] = stream


func _setup_sfx_pool() -> void:
	for i in range(SFX_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_sfx_players.append(p)


## Spielt einen Sound-Effekt per Namen ab (siehe SFX_PATHS). Unbekannte
## Namen werden nur gewarnt statt das Spiel zum Absturz zu bringen - ein
## fehlender/vertippter Sound soll nie ein Gameplay-Feature blockieren.
func play_sfx(sfx_name: String) -> void:
	var stream: AudioStream = _sfx_streams.get(sfx_name)
	if stream == null:
		push_warning("[SoundManager] Unbekannter SFX: " + sfx_name)
		return

	var p := _sfx_players[_next_sfx_player]
	_next_sfx_player = (_next_sfx_player + 1) % _sfx_players.size()
	p.stream = stream
	p.play()


func _setup_music_player() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = "Music"
	add_child(_music_player)
	_music_player.finished.connect(_play_next_track)


## Lädt alle Dateien "game_music_01.mp3", "game_music_02.mp3", ... die
## existieren (Lücken erlaubt) - neue Songs müssen nur mit fortlaufender
## Nummer benannt und ins sounds/-Verzeichnis gelegt werden, keine
## Code-Änderung nötig.
func _load_music_tracks() -> void:
	for i in range(1, MAX_MUSIC_TRACKS + 1):
		var path := MUSIC_PATH_FORMAT % i
		if not ResourceLoader.exists(path):
			continue
		var stream := load(path) as AudioStream
		if stream != null:
			_music_tracks.append(stream)


## Spielt den nächsten Song aus einer zufällig gemischten Playlist-Reihenfolge
## - wird neu gemischt sobald sie durchgelaufen ist. Bei nur einem Song läuft
## der (via AudioStreamPlayer.finished) einfach endlos weiter.
func _play_next_track() -> void:
	if _music_tracks.is_empty():
		return
	if _music_index >= _music_order.size():
		_reshuffle_order()
		_music_index = 0

	var track_index: int = _music_order[_music_index]
	_music_index += 1
	_music_player.stream = _music_tracks[track_index]
	_music_player.play()


func _reshuffle_order() -> void:
	# range() liefert ein untypisiertes Array - direkte Zuweisung an
	# Array[int] schlägt fehl, daher über den typisierten Array-Konstruktor.
	_music_order = Array(range(_music_tracks.size()), TYPE_INT, "", null)
	_music_order.shuffle()
