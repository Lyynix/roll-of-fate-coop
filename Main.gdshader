shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

// Mobile-optimized version - no NORMAL_TEXTURE dependency

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_nearest;

uniform float shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.4;
uniform float highlight_strength : hint_range(0.0, 1.0, 0.01) = 0.15;
uniform vec3 highlight_color : source_color = vec3(1.0);
uniform vec3 shadow_color : source_color = vec3(0.0);

float getDepth(vec2 screen_uv, sampler2D depth_texture, mat4 inv_projection_matrix) {
    float raw_depth = texture(depth_texture, screen_uv).r;
    vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw_depth);
    vec4 view_space = inv_projection_matrix * vec4(ndc, 1.0);
    view_space.xyz /= view_space.w;
    return -view_space.z;
}

void fragment() {
    vec2 e = vec2(1.0 / VIEWPORT_SIZE.xy);

    float depth    = getDepth(SCREEN_UV,                        DEPTH_TEXTURE, INV_PROJECTION_MATRIX);
    float du       = getDepth(SCREEN_UV + vec2( 0.0, -1.0) * e, DEPTH_TEXTURE, INV_PROJECTION_MATRIX);
    float dr       = getDepth(SCREEN_UV + vec2( 1.0,  0.0) * e, DEPTH_TEXTURE, INV_PROJECTION_MATRIX);
    float dd       = getDepth(SCREEN_UV + vec2( 0.0,  1.0) * e, DEPTH_TEXTURE, INV_PROJECTION_MATRIX);
    float dl       = getDepth(SCREEN_UV + vec2(-1.0,  0.0) * e, DEPTH_TEXTURE, INV_PROJECTION_MATRIX);

    // Shadow edges (depth discontinuities going deeper)
    float depth_diff = 0.0;
    depth_diff += clamp(du - depth, 0.0, 1.0);
    depth_diff += clamp(dd - depth, 0.0, 1.0);
    depth_diff += clamp(dr - depth, 0.0, 1.0);
    depth_diff += clamp(dl - depth, 0.0, 1.0);
    depth_diff = smoothstep(0.2, 0.3, depth_diff);

    // Highlight edges (depth discontinuities coming forward)
    float neg_depth_diff = 0.0;
    neg_depth_diff += clamp(depth - du, 0.0, 1.0);
    neg_depth_diff += clamp(depth - dd, 0.0, 1.0);
    neg_depth_diff += clamp(depth - dr, 0.0, 1.0);
    neg_depth_diff += clamp(depth - dl, 0.0, 1.0);
    neg_depth_diff = smoothstep(0.2, 0.3, neg_depth_diff);

    // Compositing - branch-free via mix()
    vec3 col = texture(SCREEN_TEXTURE, SCREEN_UV).rgb;
    col = mix(col, mix(col, shadow_color,    shadow_strength),    depth_diff);
    col = mix(col, mix(col, highlight_color, highlight_strength), neg_depth_diff);

    ALBEDO = col;
    ALPHA  = clamp((depth_diff + neg_depth_diff) * 5.0, 0.0, 1.0);
}