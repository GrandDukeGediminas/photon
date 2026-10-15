// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Texture with one fixed directional light plus ambient.
uniform sampler2D g_Texture0; // {"label":"Albedo","nonremovable":true}
uniform vec3 g_TintColor; // {"material":"tint","label":"Tint","type":"color","default":"1 1 1"}

varying vec2 v_TexCoord;
varying vec3 v_Normal;

void main() {
	vec3 light = normalize(vec3(0.4, 0.7, 0.6));
	float diffuse = max(dot(normalize(v_Normal), light), 0.0);
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	gl_FragColor = vec4(albedo.rgb * g_TintColor * (0.25 + 0.75 * diffuse), 1.0);
}
