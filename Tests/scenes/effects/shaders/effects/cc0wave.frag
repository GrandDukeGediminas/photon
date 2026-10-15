// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Sine displacement driven by g_Time.
uniform sampler2D g_Texture0; // {"hidden":true}
uniform float g_Time;
uniform float g_Strength; // {"material":"strength","label":"Strength","default":0.03,"range":[0,0.2]}
uniform float g_Frequency; // {"material":"frequency","label":"Frequency","default":8,"range":[1,40]}
varying vec2 v_TexCoord;

void main() {
	vec2 uv = v_TexCoord;
	uv.x += sin(uv.y * g_Frequency * 6.2831853 + g_Time * 2.0) * g_Strength;
	gl_FragColor = texSample2D(g_Texture0, uv);
}
