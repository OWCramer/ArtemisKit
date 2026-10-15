// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CVorbis
import Foundation

/// Decoded audio: interleaved 16-bit PCM.
public struct ArtemisPCM: Sendable {
    public let samples: [Int16]
    public let channels: Int
    public let sampleRate: Int

    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
}

/// Decodes an Ogg Vorbis file (Artemis music, effects and voices).
public func decodeOggVorbis(_ data: Data) -> ArtemisPCM? {
    var channels: Int32 = 0
    var sampleRate: Int32 = 0
    var output: UnsafeMutablePointer<Int16>?
    let frames = data.withUnsafeBytes { bytes in
        stb_vorbis_decode_memory(bytes.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &channels, &sampleRate, &output)
    }
    guard frames > 0, let output else { return nil }
    defer { free(output) }
    let samples = Array(UnsafeBufferPointer(start: output, count: Int(frames) * Int(channels)))
    return ArtemisPCM(samples: samples, channels: Int(channels), sampleRate: Int(sampleRate))
}
