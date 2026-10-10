import Foundation
import Metal
import Testing
@testable import ArtemisKit

struct ShaderProgramTests {
    /// Shaped like the newer generation's GLSL ES effects: engine uniforms, a constant array,
    /// a file-scope constant, a helper function, texture reads and the GLSL-only built-ins.
    static let sample = """
    precision highp float;
    varying vec2 resultCoord0;
    varying vec2 resultCoord1;
    uniform sampler2D textureBack;
    uniform sampler2D textureFore;
    uniform sampler2D textureUser;
    uniform float  alpha;
    uniform vec3 colorMultiply;
    uniform float  weights[4];
    uniform float  angle;   // degrees
    const vec3 luma = vec3(0.3, 0.59, 0.11);
    /* a block comment */
    float wave(float y) { return sin(radians(y * 360.0)); }
    void main()
    {
        vec2 uv = resultCoord1;
        uv.x += wave(uv.y - angle) * 0.01;
        vec4 fore = texture2D(textureFore, uv) * weights[0];
        fore += texture2D(textureFore, uv + vec2(0.001, 0.0)) * weights[1];
        vec4 user = texture2D(textureUser, resultCoord1);
        float g = dot(fore.rgb, luma);
        fore.rgb = mix(fore.rgb, vec3(g), user.a) * colorMultiply;
        if (fore.a < 0.01) { discard; }
        fore.a *= alpha * mod(atan(1.0, 1.0), 1.0);
        gl_FragColor = fore;
    }
    """

    @Test func translatesAndCompiles() throws {
        let program = try #require(ArtemisShaderProgram(glsl: Self.sample))
        #expect(program.textures == ["textureFore", "textureBack", "textureUser"])
        #expect(program.uniforms.map(\.name) == ["alpha", "colorMultiply", "weights", "angle"])
        #expect(program.floatCount == 1 + 3 + 4 + 1)
        let values = program.uniformValues(["weights": "0.5, 0.25", "angle": "90"], alpha: 0.5)
        #expect(values == [0.5, 1, 1, 1, 0.5, 0.25, 0, 0, 90])
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try device.makeLibrary(source: program.metalSource, options: nil)
        #expect(library.makeFunction(name: ArtemisShaderProgram.fragmentName) != nil)
        #expect(library.makeFunction(name: ArtemisShaderProgram.vertexName) != nil)
    }

    @Test func refusesWhatItCannotPass() {
        #expect(ArtemisShaderProgram(glsl: "uniform sampler3D volume; void main() { gl_FragColor = vec4(1.0); }") == nil)
        #expect(ArtemisShaderProgram(glsl: "uniform float x;") == nil)
    }
}
