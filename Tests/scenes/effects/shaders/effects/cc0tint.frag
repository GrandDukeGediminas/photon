// CC0 1.0: photon2 synthetic test shader (Tests/scenes/LICENSE). Mixes the layer toward a colour by luminance.
uniform sampler2D g_Texture0; // {"hidden":true}
uniform vec3 g_TintColor; // {"material":"color","label":"Colour","type":"color","default":"1 0.5 0"}
uniform float g_Amount; // {"material":"amount","label":"Amount","default":0.5,"range":[0,1]}
varying vec2 v_TexCoord;

void main() {
	vec4 c = texSample2D(g_Texture0, v_TexCoord);
	float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	c.rgb = mix(c.rgb, g_TintColor * l, g_Amount);
	gl_FragColor = c;
}
