import CoreGraphics
import Foundation

/// Artemis rule transitions (`[trans type=2 rule=... vague=...]`): the old frame dissolves
/// through a greyscale rule image, darker pixels first, with `vague` softening the edge.
/// Produces the old frame's alpha mask for a given progress, at a reduced resolution.
public struct ArtemisRuleTransition {
    public let width: Int
    public let height: Int
    private let rule: [UInt8]
    private let vague: Double

    public init?(rule image: CGImage, width: Int = 320, height: Int = 180, vague: Double) {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        rule = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
        self.width = width
        self.height = height
        self.vague = max(1, vague)
    }

    /// The old frame's opacity per pixel at `progress` (0...1): opaque where it still shows.
    public func oldFrameMask(progress: Double) -> CGImage? {
        let threshold = progress * (255 + vague) - vague
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< rule.count {
            let alpha = min(1, max(0, (Double(rule[i]) - threshold) / vague))
            let value = UInt8(alpha * 255)
            // Premultiplied white with that alpha; a layer mask only reads alpha.
            pixels[i * 4] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = value
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
