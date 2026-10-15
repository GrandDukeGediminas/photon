// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Static mesh with a world-space normal.
uniform mat4 g_ModelViewProjectionMatrix;
uniform mat4 g_ModelMatrix;

attribute vec3 a_Position;
attribute vec3 a_Normal;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec3 v_Normal;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_Normal = normalize(mul(vec4(a_Normal, 0.0), g_ModelMatrix).xyz);
	v_TexCoord = a_TexCoord;
}
