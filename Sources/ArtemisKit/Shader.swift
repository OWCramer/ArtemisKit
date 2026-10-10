import CoreImage
import Foundation

/// One of the newer generation's pixel shaders (`lyshader` loads them, `lyprop shader=`
/// applies one, `shaderconstant` lists its parameters), done with Core Image filters on the
/// layer's image. The games ship them as HLSL/GLSL; what each does is read from NUKITASHI's
/// `system/image/shader.lua`, which sets them: colour tints for the time of day (`cmul`),
/// grey, sepia, negative, colour add/subtract, the Gaussian blur pair and mosaic. The
/// animated distortions (raster scroll) and two-texture composites are left unfiltered.
public struct ArtemisShader: Equatable, Sendable {
    public var name: String
    public var values: [String: String]
    /// `shadertexture`: extra samplers by name (`textureUser`) and the layers they show.
    public var textures: [String: String] = [:]

    var key: String { name + "(" + values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: ",") + ")" }

    private func number(_ key: String, _ fallback: Double = 0) -> Double {
        values[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? fallback
    }

    /// red, green, blue as 0...1.
    private var color: (CGFloat, CGFloat, CGFloat) {
        (CGFloat(number("red", 1)), CGFloat(number("green", 1)), CGFloat(number("blue", 1)))
    }

    private static func multiply(_ image: CIImage, _ c: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: c.0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: c.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: c.2, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Adds to the colour (Core Image's colour matrix works on unpremultiplied colour, so
    /// transparent pixels stay clear).
    private static func add(_ image: CIImage, _ c: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: c.0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: c.1),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: c.2), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    private static func gray(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    }

    func apply(to image: CIImage, extent: CGRect) -> CIImage {
        switch name {
        case "gray":
            return Self.gray(image)
        case "nega":
            return image.applyingFilter("CIColorInvert")
        case "cmul", "mul":
            return Self.multiply(image, color)
        case "cadd", "add", "rgb":
            return Self.add(image, color)
        case "csub":
            let c = color
            return Self.add(image, (-c.0, -c.1, -c.2))
        case "sepia", "sepia2":
            // Grey, then tinted by the game's sepia colour.
            return Self.multiply(Self.gray(image), color)
        case "blur_h", "blur_v":
            // The game passes up to eight Gaussian weights; how many it uses is the radius.
            let weights = (values["weights"] ?? "").split(separator: ",").compactMap { Double($0) }.filter { $0 > 0 }
            guard !weights.isEmpty else { return image }
            return image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(weights.count) * 0.75])
                .cropped(to: extent)
        case "fglass":
            return image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: number("size", 5)])
                .cropped(to: extent)
        case "mosaic":
            // `size` is the number of cells across.
            let cells = number("size")
            guard cells > 0 else { return image }
            return image.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, extent.width / cells),
                                                           kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)])
                .cropped(to: extent)
        case "uzumaki":
            return image.clampedToExtent()
                .applyingFilter("CITwirlDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputRadiusKey: min(extent.width, extent.height) / 2,
                    kCIInputAngleKey: number("size", 0.1) * number("radius", 2) * .pi * 10,
                ])
                .cropped(to: extent)
        default:
            return image
        }
    }
}
