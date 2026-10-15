// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Texture times brightness and alpha.
uniform sampler2D g_Texture0; // {"label":"Albedo","nonremovable":true}
uniform float g_Brightness; // {"material":"Brightness","label":"Brightness","default":1,"range":[0,2]}
uniform float g_UserAlpha; // {"material":"Alpha","label":"Alpha","default":1,"range":[0,1]}

varying vec2 v_TexCoord;

void main() {
	vec4 color = texSample2D(g_Texture0, v_TexCoord);
	color.rgb *= g_Brightness;
	color.a *= g_UserAlpha;
	gl_FragColor = color;
}
