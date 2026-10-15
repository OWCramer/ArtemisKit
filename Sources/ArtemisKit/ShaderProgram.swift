// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A game's own pixel shader, translated to Metal. The newer generation ships its effects as
/// GLSL ES fragment shaders (`system/shader/mb`, `sw`) beside the HLSL the Windows build
/// loads; `lyshader` names them and `lyprop shader=` applies one to a layer. Translating
/// the game's source keeps every effect a game brings, not only the ones written by hand.
///
/// The engine's conventions: `textureFore` is the layer (or its offscreen group, with
/// `intermediate_render`), sampled at `resultCoord1`; `textureBack` what is behind it, at
/// `resultCoord0`; `textureMask` a mask; other samplers are named by `shadertexture`. Colour
/// is straight (not premultiplied) alpha, and `alpha` / `colorMultiply` are the layer's.
/// Every other uniform comes from `shaderconstant`.
public struct ArtemisShaderProgram: Sendable {
    public struct Uniform: Sendable {
        public let name: String
        /// Offset in the float buffer the fragment function reads.
        public let offset: Int
        /// Floats per element (1 float, 2-4 vectors, 4/9/16 matrices).
        public let components: Int
        public let count: Int
    }

    /// Metal source with the vertex function `program_vertex` and fragment `program_fragment`.
    public let metalSource: String
    public let uniforms: [Uniform]
    public let floatCount: Int
    /// Sampler names in texture-slot order.
    public let textures: [String]

    public static let vertexName = "program_vertex"
    public static let fragmentName = "program_fragment"

    /// Nil when the source isn't a fragment shader this can translate.
    public init?(glsl source: String) {
        var text = Self.stripComments(source)
        // Directives GLSL ES needs and Metal doesn't.
        text = text.replacingOccurrences(of: #"(?m)^\s*(precision\s+\w+\s+\w+\s*;|#version.*$|#extension.*$)"#, with: "",
                                         options: .regularExpression)

        // Uniforms and varyings at file scope become the fragment function's inputs.
        var uniforms: [Uniform] = []
        var textures: [String] = []
        var offset = 0
        let declaration = try! NSRegularExpression(
            pattern: #"\b(uniform|varying|attribute)\s+(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+([^;]+);"#)
        var unsupported = false
        let ns = text as NSString
        var kept = ""
        var last = 0
        for match in declaration.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            kept += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let kind = ns.substring(with: match.range(at: 1))
            let type = ns.substring(with: match.range(at: 2))
            guard kind == "uniform" else { continue } // varyings: the coordinates, set below
            for raw in ns.substring(with: match.range(at: 3)).split(separator: ",") {
                let item = raw.trimmingCharacters(in: .whitespaces)
                var name = item
                var count = 1
                if let open = item.firstIndex(of: "["), let close = item.firstIndex(of: "]") {
                    name = String(item[..<open]).trimmingCharacters(in: .whitespaces)
                    count = Int(item[item.index(after: open)..<close].trimmingCharacters(in: .whitespaces)) ?? 1
                }
                if type == "sampler2D" {
                    textures.append(name)
                    continue
                }
                guard let components = Self.components[type] else {
                    unsupported = true
                    continue
                }
                uniforms.append(Uniform(name: name, offset: offset, components: components, count: count))
                offset += components * count
            }
        }
        kept += ns.substring(from: last)
        guard !unsupported else { return nil }
        text = kept
        // textureFore first: the layer itself.
        if let index = textures.firstIndex(of: "textureFore") {
            textures.remove(at: index)
            textures.insert("textureFore", at: 0)
        }

        // main() becomes the fragment function; file-scope constants go in `constant` space.
        guard let mainRange = text.range(of: #"void\s+main\s*\(\s*(void)?\s*\)\s*\{"#, options: .regularExpression),
              let bodyEnd = Self.matchingBrace(in: text, openingAt: text.index(before: mainRange.upperBound)) else { return nil }
        let before = Self.constantsAtFileScope(String(text[..<mainRange.lowerBound]))
        var body = String(text[mainRange.upperBound..<bodyEnd])
        let after = String(text[text.index(after: bodyEnd)...])
        body = body.replacingOccurrences(of: #"\breturn\s*;"#, with: "return artemis_out(gl_FragColor);", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\bdiscard\s*;"#, with: "discard_fragment();", options: .regularExpression)

        var parameters = ["ArtemisProgramOut in [[stage_in]]", "constant float *U [[buffer(0)]]"]
        for (slot, name) in textures.enumerated() { parameters.append("texture2d<float> \(name) [[texture(\(slot))]]") }
        parameters.append("sampler artemis_sampler [[sampler(0)]]")
        var prologue = [
            "float4 gl_FragColor = float4(0.0);",
            "float4 gl_FragCoord = in.position;",
            "float2 resultCoord0 = in.uv;",
            "float2 resultCoord1 = in.uv;",
        ]
        for uniform in uniforms {
            let type = Self.metalType(components: uniform.components)
            func element(_ base: Int) -> String {
                let floats = (0 ..< uniform.components).map { "U[\(base + $0)]" }.joined(separator: ", ")
                return uniform.components == 1 ? "U[\(base)]" : "\(type)(\(floats))"
            }
            if uniform.count == 1 {
                prologue.append("\(type) \(uniform.name) = \(element(uniform.offset));")
            } else {
                prologue.append("\(type) \(uniform.name)[\(uniform.count)];")
                for i in 0 ..< uniform.count {
                    prologue.append("\(uniform.name)[\(i)] = \(element(uniform.offset + i * uniform.components));")
                }
            }
        }

        metalSource = Self.header + before + """

        fragment float4 \(Self.fragmentName)(\(parameters.joined(separator: ", "))) {
            \(prologue.joined(separator: "\n    "))
        \(body)
            return artemis_out(gl_FragColor);
        }
        """ + after
        self.uniforms = uniforms
        self.floatCount = max(1, offset)
        self.textures = textures
    }

    /// The uniform buffer: the layer's alpha and colour multiply, the shader's constants
    /// (comma-separated for vectors), zero for anything unset.
    public func uniformValues(_ values: [String: String], alpha: Float = 1, colorMultiply: SIMD3<Float> = SIMD3(1, 1, 1)) -> [Float] {
        var buffer = [Float](repeating: 0, count: floatCount)
        for uniform in uniforms {
            var numbers: [Float]
            switch uniform.name {
            case "alpha": numbers = [alpha]
            case "colorMultiply": numbers = [colorMultiply.x, colorMultiply.y, colorMultiply.z]
            default:
                numbers = (values[uniform.name] ?? "").split(separator: ",")
                    .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            }
            for (i, number) in numbers.prefix(uniform.components * uniform.count).enumerated() {
                buffer[uniform.offset + i] = number
            }
        }
        return buffer
    }

    // MARK: Translation helpers

    private static let components: [String: Int] = [
        "float": 1, "int": 1, "bool": 1, "vec2": 2, "vec3": 3, "vec4": 4,
        "ivec2": 2, "ivec3": 3, "ivec4": 4, "mat2": 4, "mat3": 9, "mat4": 16,
    ]

    private static func metalType(components: Int) -> String {
        switch components {
        case 2: return "float2"
        case 3: return "float3"
        case 4: return "float4"
        case 9: return "float3x3"
        case 16: return "float4x4"
        default: return "float"
        }
    }

    private static func stripComments(_ source: String) -> String {
        source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
    }

    private static func matchingBrace(in text: String, openingAt open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `const` declarations outside any function go in Metal's constant address space.
    private static func constantsAtFileScope(_ text: String) -> String {
        var result = ""
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth == 0, text[index...].hasPrefix("const "),
               index == text.startIndex || !(text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber) {
                result += "constant "
                index = text.index(index, offsetBy: 6)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// GLSL ES spellings mapped onto Metal, and the engine's sampling: textures hold
    /// premultiplied colour, the game's shaders expect straight alpha.
    static let header = """
    #include <metal_stdlib>
    using namespace metal;

    struct ArtemisProgramVertex { float2 position; float2 uv; };
    struct ArtemisProgramOut { float4 position [[position]]; float2 uv; };

    vertex ArtemisProgramOut program_vertex(uint id [[vertex_id]], const device ArtemisProgramVertex *vertices [[buffer(0)]]) {
        ArtemisProgramOut out;
        out.position = float4(vertices[id].position, 0, 1);
        out.uv = vertices[id].uv;
        return out;
    }

    static float4 artemis_sample(texture2d<float> t, sampler s, float2 c) {
        float4 p = t.sample(s, c);
        return p.a > 0.0 ? float4(p.rgb / p.a, p.a) : float4(0.0);
    }
    static float4 artemis_out(float4 c) {
        float a = clamp(c.a, 0.0, 1.0);
        return float4(clamp(c.rgb, 0.0, 1.0) * a, a);
    }
    static float artemis_atan(float x) { return atan(x); }
    static float artemis_atan(float y, float x) { return atan2(y, x); }
    static float2 artemis_atan(float2 y, float2 x) { return atan2(y, x); }
    static float3 artemis_atan(float3 y, float3 x) { return atan2(y, x); }
    template <typename T, typename U> static T artemis_mod(T x, U y) { return x - y * floor(x / y); }

    #define lowp
    #define mediump
    #define highp
    #define vec2 float2
    #define vec3 float3
    #define vec4 float4
    #define ivec2 int2
    #define ivec3 int3
    #define ivec4 int4
    #define bvec2 bool2
    #define bvec3 bool3
    #define bvec4 bool4
    #define mat2 float2x2
    #define mat3 float3x3
    #define mat4 float4x4
    #define texture2D(t, c) artemis_sample(t, artemis_sampler, c)
    #define texture2DLod(t, c, l) artemis_sample(t, artemis_sampler, c)
    #define inversesqrt rsqrt
    #define atan artemis_atan
    #define mod(x, y) artemis_mod(x, y)
    #define radians(x) ((x) * 0.017453292519943295)
    #define degrees(x) ((x) * 57.29577951308232)
    #define lessThan(a, b) ((a) < (b))
    #define lessThanEqual(a, b) ((a) <= (b))
    #define greaterThan(a, b) ((a) > (b))
    #define greaterThanEqual(a, b) ((a) >= (b))
    #define equal(a, b) ((a) == (b))
    #define notEqual(a, b) ((a) != (b))

    """
}
