// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Testing
@testable import ArtemisKit

@Suite struct RuleTransitionTests {
    /// A 2x1 rule: black on the left, white on the right.
    private func rule() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 2,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.data!.assumingMemoryBound(to: UInt8.self)[0] = 0
        context.data!.assumingMemoryBound(to: UInt8.self)[1] = 255
        return context.makeImage()!
    }

    private func alphas(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0 ..< image.width).map { bytes[$0 * 4 + 3] }
    }

    @Test func darkPixelsClearFirst() throws {
        let transition = try #require(ArtemisRuleTransition(rule: rule(), width: 2, height: 1, vague: 32))
        #expect(alphas(try #require(transition.oldFrameMask(progress: 0))) == [255, 255])
        #expect(alphas(try #require(transition.oldFrameMask(progress: 1))) == [0, 0])
        let middle = alphas(try #require(transition.oldFrameMask(progress: 0.5)))
        #expect(middle[0] == 0)
        #expect(middle[1] == 255)
    }
}
