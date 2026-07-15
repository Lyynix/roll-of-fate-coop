shader_type particles;

uniform float sphere_radius : hint_range(0.5, 3.0) = 1.5;
uniform float cone_half_angle : hint_range(0.0, 1.57) = 0.5;
uniform float phase_split : hint_range(0.05, 0.9) = 0.28;
// Wie weit der Kegel-Launch über den Ursprung hinausschießt, bevor der
// magnetische Einzug übernimmt (als Vielfaches von sphere_radius).
uniform float launch_reach : hint_range(0.1, 2.0) = 0.6;
// Absolute Zeit (Sekunden) bis ein Partikel sein Ziel erreicht - unabhängig
// von LIFETIME. LIFETIME steuert nur noch, wie lange ein Partikel danach
// ruhig auf der Sphäre sitzt, bevor es ausblendet.
uniform float travel_time : hint_range(0.05, 3.0) = 0.4;

uint hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

float randf(uint seed) {
    return float(hash(seed)) / 4294967295.0;
}

// Gleichmäßig zufälliger Punkt auf Einheitskugel
vec3 sphere_point(uint seed) {
    float u   = randf(seed) * 2.0 - 1.0;
    float phi = randf(hash(seed)) * 2.0 * PI;
    float r   = sqrt(max(0.0, 1.0 - u * u));
    return vec3(cos(phi) * r, u, sin(phi) * r);
}

// Kegelrichtung aus INDEX: stabil pro Partikel-Lifetime, verschieden per Partikel
vec3 cone_dir_from_index(uint idx, float half_angle) {
    uint s      = hash(idx * 2654435761u + 7919u);
    float cos_t = mix(cos(half_angle), 1.0, randf(s));
    float sin_t = sqrt(max(0.0, 1.0 - cos_t * cos_t));
    float phi   = randf(hash(s)) * 2.0 * PI;
    return vec3(cos(phi) * sin_t, cos_t, sin(phi) * sin_t);
}

void process() {
    if (RESTART) {
        CUSTOM.w = 0.0;
        // RANDOM_SEED ist in Godot 4 für alle Partikel eines Frames gleich –
        // INDEX differenziert Partikel innerhalb eines Bursts,
        // RANDOM_SEED variiert das Muster zwischen Bursts.
        // Ziel einmalig hier berechnen und in CUSTOM.xyz speichern,
        // damit es pro Lifetime stabil bleibt (nicht jedes Frame neu berechnet).
        uint seed  = hash(INDEX * 2654435761u ^ RANDOM_SEED);
        CUSTOM.xyz = sphere_point(seed);
    }

    CUSTOM.w += DELTA;
    // t_full läuft über die komplette Lebenszeit (steuert nur das Ausblenden),
    // t_travel läuft über die feste travel_time (steuert die Bewegung) und
    // bleibt danach bei 1.0 stehen - das Partikel ruht am Ziel.
    float t_full   = clamp(CUSTOM.w / LIFETIME, 0.0, 1.0);
    float t_travel = clamp(CUSTOM.w / travel_time, 0.0, 1.0);

    vec3 target   = CUSTOM.xyz * sphere_radius;
    vec3 launch   = cone_dir_from_index(INDEX, cone_half_angle);
    vec3 origin   = vec3(0.0, 0.5, 0.0);
    vec3 waypoint = origin + launch * (sphere_radius * launch_reach);

    vec3  pos;
    float alpha_in;

    if (t_travel < phase_split) {
        float pt = smoothstep(0.0, 1.0, t_travel / phase_split);
        pos      = mix(origin, waypoint, pt);
        alpha_in = pt;
    } else {
        float pt   = (t_travel - phase_split) / (1.0 - phase_split);
        float ease = 1.0 - pow(1.0 - pt, 2.5);
        pos        = mix(waypoint, target, ease);
        alpha_in   = 1.0;
    }

    TRANSFORM[3].xyz = pos;

    float alpha_out = 1.0 - smoothstep(0.8, 1.0, t_full);
    vec3 col = mix(
        vec3(0.75, 0.93, 1.0),
        vec3(0.20, 0.55, 1.0),
        smoothstep(0.0, 0.7, t_travel)
    );
    COLOR = vec4(col, alpha_in * alpha_out);
}
