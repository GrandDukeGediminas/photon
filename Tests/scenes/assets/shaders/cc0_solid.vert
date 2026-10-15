// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Untextured quads (text backgrounds).
uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;

void main() {
	gl_Position = mul(vec4(a_Position.xy, 0.0, 1.0), g_ModelViewProjectionMatrix);
}
