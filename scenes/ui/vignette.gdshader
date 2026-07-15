shader_type canvas_item;

// HP-Warnung: dunkelroter Rand-Schatten, dessen Deckkraft über intensity
// (von hud.gd per Tween) gesteuert wird. radial statt rechteckig, damit es
// wie ein weicher Schatten und nicht wie ein hartes Rechteck wirkt.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec4 vignette_color : source_color = vec4(0.35, 0.0, 0.0, 1.0);
uniform float inner_radius : hint_range(0.0, 1.0) = 0.35;
uniform float outer_radius : hint_range(0.0, 1.5) = 0.85;

void fragment() {
	vec2 centered = UV - vec2(0.5);
	// *sqrt(2): normiert den Abstand so, dass er in den Bildecken ~1.0
	// erreicht (Diagonale des UV-Quadrats), nicht erst bei UV-Rand-Mitte.
	float dist = length(centered) * 1.4142135;
	float vig = smoothstep(inner_radius, outer_radius, dist);
	COLOR = vec4(vignette_color.rgb, vig * intensity * vignette_color.a);
}
