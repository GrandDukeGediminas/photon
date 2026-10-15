// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Camera-facing particle quads without a geometry stage:
// a_Position is the particle centre, a_TexCoordVec4 = (corner u, corner v, rotation, size), a_Color its colour.
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec3 g_OrientationUp;
uniform vec3 g_OrientationRight;

attribute vec3 a_Position;
attribute vec4 a_TexCoordVec4;
attribute vec2 a_TexCoordC2;
attribute vec4 a_Color;

varying vec2 v_TexCoord;
varying vec4 v_Color;

void main() {
	vec2 corner = a_TexCoordVec4.xy - vec2(0.5, 0.5);
	float angle = a_TexCoordVec4.z;
	vec2 r = vec2(corner.x * cos(angle) - corner.y * sin(angle), corner.x * sin(angle) + corner.y * cos(angle));
	vec3 position = a_Position + (g_OrientationRight * r.x - g_OrientationUp * r.y) * a_TexCoordVec4.w;
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoordVec4.xy;
	v_Color = a_Color;
}
