// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Coverage atlas (R8) or colour atlas (COLORFONT) times
// the text colour.
uniform vec4 g_Color4;
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;

void main() {
#if COLORFONT
	vec4 s = texSample2D(g_Texture0, v_TexCoord);
	gl_FragColor = vec4(s.rgb, s.a * g_Color4.a);
#else
	float coverage = texSample2D(g_Texture0, v_TexCoord).r;
	gl_FragColor = vec4(g_Color4.rgb, coverage * g_Color4.a);
#endif
}
