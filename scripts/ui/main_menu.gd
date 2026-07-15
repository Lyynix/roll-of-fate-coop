extends CanvasLayer

const SETTINGS_PATH := "user://settings.cfg"

@onready var main_buttons: Control = $CenterContainer
@onready var highscore_label: Label = $CenterContainer/VBoxContainer/HighscoreLabel
@onready var new_game_button: Button = $CenterContainer/VBoxContainer/NewGameButton
@onready var resume_button: Button = $CenterContainer/VBoxContainer/ResumeButton
@onready var credits_button: Button = $CenterContainer/VBoxContainer/CreditsButton
@onready var settings_button: Button = $CenterContainer/VBoxContainer/SettingsButton
@onready var quit_button: Button = $CenterContainer/VBoxContainer/QuitButton

@onready var credits_panel: Control = $CreditsPanel
@onready var credits_back_button: Button = $CreditsPanel/CenterContainer/VBoxContainer/BackButton
@onready var sound_credit_link: LinkButton = $"CreditsPanel/CenterContainer/VBoxContainer/VBoxContainer/Dominik Braun"
@onready var license_link: LinkButton = $"CreditsPanel/CenterContainer/VBoxContainer/VBoxContainer/CC BY"

@onready var settings_panel: Control = $SettingsPanel
@onready var settings_back_button: Button = $SettingsPanel/CenterContainer/VBoxContainer/BackButton
@onready var music_mute_button: Button = $SettingsPanel/CenterContainer/VBoxContainer/MusicRow/MusicMuteButton
@onready var music_slider: HSlider = $SettingsPanel/CenterContainer/VBoxContainer/MusicRow/MusicSlider
@onready var sfx_mute_button: Button = $SettingsPanel/CenterContainer/VBoxContainer/SfxRow/SfxMuteButton
@onready var sfx_slider: HSlider = $SettingsPanel/CenterContainer/VBoxContainer/SfxRow/SfxSlider

@onready var coop_button: Button = $CenterContainer/VBoxContainer/CoopButton
@onready var coop_panel: Control = $CoopPanel
@onready var coop_name_edit: LineEdit = $CoopPanel/CenterContainer/VBoxContainer/NameEdit
@onready var coop_status_label: Label = $CoopPanel/CenterContainer/VBoxContainer/StatusLabel
@onready var coop_host_button: Button = $CoopPanel/CenterContainer/VBoxContainer/HostButton
@onready var coop_host_list: VBoxContainer = $CoopPanel/CenterContainer/VBoxContainer/HostListContainer
@onready var coop_cancel_button: Button = $CoopPanel/CenterContainer/VBoxContainer/CancelButton
@onready var coop_start_button: Button = $CoopPanel/CenterContainer/VBoxContainer/StartGameButton
@onready var coop_back_button: Button = $CoopPanel/CenterContainer/VBoxContainer/BackButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	new_game_button.pressed.connect(_on_new_game_pressed)
	resume_button.pressed.connect(_on_resume_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	credits_button.pressed.connect(_on_credits_pressed)
	credits_back_button.pressed.connect(_on_credits_back_pressed)
	# LinkButton öffnet seine uri selbst - hier nur noch der Klick-Sound.
	sound_credit_link.pressed.connect(_on_credit_link_pressed)
	license_link.pressed.connect(_on_credit_link_pressed)

	settings_button.pressed.connect(_on_settings_pressed)
	settings_back_button.pressed.connect(_on_settings_back_pressed)
	music_slider.value_changed.connect(_on_music_volume_changed)
	sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	music_mute_button.toggled.connect(_on_music_mute_toggled)
	sfx_mute_button.toggled.connect(_on_sfx_mute_toggled)
	_load_settings()

	coop_button.pressed.connect(_on_coop_pressed)
	coop_host_button.pressed.connect(_on_coop_host_pressed)
	coop_cancel_button.pressed.connect(_on_coop_cancel_pressed)
	coop_start_button.pressed.connect(_on_coop_start_pressed)
	coop_back_button.pressed.connect(_on_coop_back_pressed)
	coop_name_edit.text_changed.connect(_on_coop_name_changed)
	coop_name_edit.focus_exited.connect(_on_coop_name_focus_exited)
	NetworkManager.host_found.connect(_on_network_host_found)
	NetworkManager.host_lost.connect(_on_network_host_lost)
	NetworkManager.connected.connect(_on_network_connected)
	NetworkManager.disconnected.connect(_on_network_disconnected)
	GameManager.highscore_changed.connect(_on_highscore_changed)

	_refresh_resume_button()


func _on_credit_link_pressed() -> void:
	SoundManager.play_sfx("ui_tap")


func _on_highscore_changed(_new_highscore: int) -> void:
	_update_highscore_label()
	_save_settings()


func _update_highscore_label() -> void:
	highscore_label.text = "Highscore: %d Pkt." % GameManager.highscore


func _refresh_resume_button() -> void:
	resume_button.disabled = not GameManager.has_active_game


## Vom Pause-Button im HUD aufgerufen, um mitten im Run zum Menü
## zurückzukehren, ohne den laufenden Stand zu verlieren.
func open() -> void:
	_refresh_resume_button()
	_show_main_buttons()
	get_tree().paused = true
	show()


func _on_new_game_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	get_tree().paused = false
	hide()
	GameManager.start_game()


func _on_resume_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	get_tree().paused = false
	hide()


func _on_quit_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	get_tree().quit()


func _on_credits_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	_hide_all_panels()
	credits_panel.show()


func _on_credits_back_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	_show_main_buttons()


func _on_settings_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	_hide_all_panels()
	settings_panel.show()


func _on_settings_back_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	_show_main_buttons()


func _show_main_buttons() -> void:
	_hide_all_panels()
	main_buttons.show()


func _hide_all_panels() -> void:
	main_buttons.hide()
	credits_panel.hide()
	settings_panel.hide()
	coop_panel.hide()


# ══════════════════════════════════════════
#  Koop (WLAN-Discovery, Verbindungsaufbau & Spielstart)
# ══════════════════════════════════════════

func _on_coop_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	_hide_all_panels()
	coop_panel.show()
	coop_name_edit.text = NetworkManager.local_name
	_reset_coop_search_ui()
	NetworkManager.start_discovery()


## Live-Übernahme bei jedem Tastendruck, damit der Name schon aktuell ist,
## sobald "Hosten" getippt oder ein gefundenes Spiel angetippt wird - erst
## bei Fokus-Verlust wird tatsächlich auf die Festplatte gespeichert
## (_on_coop_name_focus_exited()), um nicht bei jedem Buchstaben zu schreiben.
func _on_coop_name_changed(new_text: String) -> void:
	NetworkManager.local_name = new_text


## Leerer Name nach dem Editieren wäre auf dem Koop-Bildschirm der anderen
## Seite verwirrend - fällt in dem Fall auf einen frischen Vorschlag zurück
## statt einen leeren String zu persistieren.
func _on_coop_name_focus_exited() -> void:
	var trimmed := coop_name_edit.text.strip_edges()
	if trimmed == "":
		trimmed = NetworkManager.generate_default_name()
		coop_name_edit.text = trimmed
	NetworkManager.local_name = trimmed
	_save_settings()


func _reset_coop_search_ui() -> void:
	_clear_host_list()
	coop_status_label.text = "Suche nach Spielen …"
	coop_host_button.show()
	coop_host_list.show()
	coop_cancel_button.hide()
	coop_start_button.hide()


func _clear_host_list() -> void:
	for child in coop_host_list.get_children():
		child.queue_free()


func _on_coop_host_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	NetworkManager.start_hosting()
	coop_status_label.text = "Warte auf Mitspieler …"
	coop_host_button.hide()
	coop_host_list.hide()
	coop_cancel_button.show()


## Fügt einen per UDP-Broadcast gefundenen Host als antippbaren Eintrag hinzu -
## der Name "Host_<ip>" macht den Eintrag in _on_network_host_lost() wieder
## eindeutig auffindbar, ohne eine separate IP->Node-Zuordnung pflegen zu müssen.
func _on_network_host_found(ip: String, info: Dictionary) -> void:
	var entry := Button.new()
	entry.name = "Host_" + ip
	entry.custom_minimum_size = Vector2(480, 80)
	entry.add_theme_font_size_override("font_size", 28)
	entry.text = str(info.get("name", ip))
	entry.pressed.connect(_on_coop_host_selected.bind(ip, int(info.get("tcp_port", NetworkManager.TCP_PORT))))
	coop_host_list.add_child(entry)


func _on_network_host_lost(ip: String) -> void:
	var entry := coop_host_list.get_node_or_null("Host_" + ip)
	if entry != null:
		entry.queue_free()


func _on_coop_host_selected(ip: String, port: int) -> void:
	SoundManager.play_sfx("ui_tap")
	NetworkManager.connect_to_host(ip, port)
	coop_status_label.text = "Verbinde …"
	coop_host_button.hide()
	coop_host_list.hide()
	coop_cancel_button.show()


## Host: bekommt einen "Los geht's"-Button, da der Host entscheidet, wann der
## Lauf startet (host-autoritativ). Secondary: kein Button - startet
## stattdessen sofort selbst im Hintergrund und hängt dabei in
## GameManager._sync_level() am Warten auf die level_data-Nachricht vom Host,
## bis der "Los geht's" tippt.
func _on_network_connected(peer_name: String) -> void:
	coop_cancel_button.hide()
	if NetworkManager.role == NetworkManager.Role.HOST:
		coop_status_label.text = "Verbunden mit " + peer_name + "! Bereit."
		coop_start_button.show()
	else:
		coop_status_label.text = "Verbunden mit " + peer_name + "! Warte auf Host …"
		_start_coop_run()


## Behandelt nur den Abbruch während der Lobby-Suche (Koop-Panel noch offen):
## zurück in den Suchmodus. Ein Verbindungsabbruch mitten in einer laufenden
## Partie wird stattdessen von GameManager._on_network_disconnected()
## behandelt (harter Szenen-Reload).
func _on_network_disconnected() -> void:
	if not coop_panel.visible:
		return
	_reset_coop_search_ui()
	NetworkManager.start_discovery()
	coop_status_label.text = "Verbindung getrennt. Suche nach Spielen …"


func _on_coop_cancel_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	NetworkManager.stop()
	_reset_coop_search_ui()
	NetworkManager.start_discovery()


func _on_coop_start_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	_start_coop_run()


func _start_coop_run() -> void:
	get_tree().paused = false
	hide()
	GameManager.start_game()


func _on_coop_back_pressed() -> void:
	SoundManager.play_sfx("ui_tap")
	NetworkManager.stop()
	_show_main_buttons()


# ══════════════════════════════════════════
#  Lautstärke-Einstellungen (Musik/SFX-Busse)
# ══════════════════════════════════════════

## 0-10-Skala (Slider-Wert) auf Dezibel gemappt: 10 = 0dB (aktuelle Lautstärke
## unverändert), 0 = praktisch stumm. linear_to_db(0.0) wäre -INF, daher der
## Sonderfall für 0.
func _apply_volume(bus_name: String, slider_value: float) -> void:
	var bus_idx := AudioServer.get_bus_index(bus_name)
	if slider_value <= 0.0:
		AudioServer.set_bus_volume_db(bus_idx, -80.0)
	else:
		AudioServer.set_bus_volume_db(bus_idx, linear_to_db(slider_value / 10.0))


func _on_music_volume_changed(value: float) -> void:
	_apply_volume("Music", value)
	_save_settings()


func _on_sfx_volume_changed(value: float) -> void:
	_apply_volume("SFX", value)
	SoundManager.play_sfx("ui_tap")
	_save_settings()


func _on_music_mute_toggled(muted: bool) -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), muted)
	_save_settings()


func _on_sfx_mute_toggled(muted: bool) -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("SFX"), muted)
	_save_settings()


func _load_settings() -> void:
	var config := ConfigFile.new()
	var loaded := config.load(SETTINGS_PATH) == OK

	var music_volume: float = config.get_value("audio", "music_volume", 10.0) if loaded else 10.0
	var sfx_volume: float = config.get_value("audio", "sfx_volume", 10.0) if loaded else 10.0
	var music_muted: bool = config.get_value("audio", "music_muted", false) if loaded else false
	var sfx_muted: bool = config.get_value("audio", "sfx_muted", false) if loaded else false

	music_slider.value = music_volume
	sfx_slider.value = sfx_volume
	music_mute_button.button_pressed = music_muted
	sfx_mute_button.button_pressed = sfx_muted

	_apply_volume("Music", music_volume)
	_apply_volume("SFX", sfx_volume)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), music_muted)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("SFX"), sfx_muted)

	GameManager.highscore = config.get_value("game", "highscore", 0) if loaded else 0
	_update_highscore_label()

	# Nur übernehmen wenn tatsächlich ein zuvor gespeicherter Name existiert -
	# sonst bleibt NetworkManager.local_name beim automatisch vorgeschlagenen
	# Standardnamen (siehe NetworkManager.generate_default_name()), den der
	# Nutzer beim ersten Öffnen des Koop-Panels als Vorschlag sieht.
	var saved_name: String = config.get_value("network", "player_name", "") if loaded else ""
	if saved_name != "":
		NetworkManager.local_name = saved_name


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("audio", "music_volume", music_slider.value)
	config.set_value("audio", "sfx_volume", sfx_slider.value)
	config.set_value("audio", "music_muted", music_mute_button.button_pressed)
	config.set_value("audio", "sfx_muted", sfx_mute_button.button_pressed)
	config.set_value("game", "highscore", GameManager.highscore)
	config.set_value("network", "player_name", NetworkManager.local_name)
	config.save(SETTINGS_PATH)
