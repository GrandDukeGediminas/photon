// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Particle texture times the particle colour.
uniform sampler2D g_Texture0; // {"label":"Albedo","nonremovable":true}
uniform float g_Overbright; // {"material":"overbright","label":"Overbright","default":1,"range":[0,5]}

varying vec2 v_TexCoord;
varying vec4 v_Color;

void main() {
	vec4 color = texSample2D(g_Texture0, v_TexCoord) * v_Color;
	color.rgb *= g_Overbright;
	gl_FragColor = color;
}
