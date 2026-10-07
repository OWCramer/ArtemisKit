import Accelerate
import CoreGraphics
import CVideo
import Foundation

/// A video decoded in software: Ogg Theora (the engine's video layers) or MPEG-1 (the
/// Windows builds' full-screen movies). Frames follow a clock in milliseconds and come out
/// as `CGImage`s for a layer or a presenter to show.
public final class ArtemisVideo {
    private enum Decoder {
        case theora(OpaquePointer)
        case mpeg(OpaquePointer)
    }

    public let width: Int
    public let height: Int
    public let frameRate: Double
    public var loop: Bool
    /// The picture for the current time.
    public private(set) var image: CGImage?
    /// Reached the end (never, while looping).
    public private(set) var isFinished = false
    /// MPEG-1 movies carry MP2 audio; see `audio(upTo:)`.
    public let hasAudio: Bool
    public let audioSampleRate: Int

    private var decoder: Decoder
    /// `foo_m.ogv` beside `foo.ogv`: a grayscale video whose brightness is the alpha.
    public var mask: ArtemisVideo?
    /// Clock time of the first frame; set by the first update.
    private var startTime: Double?
    private var framesDecoded = 0
    private var conversion = vImage_YpCbCrToARGB()
    /// MPEG: a second reader over the same file for the audio track, so video and audio
    /// decode independently.
    private var audioDecoder: OpaquePointer?
    private var audioDecodedSeconds = 0.0
    private let memory: UnsafeMutableRawPointer?

    /// A video held in memory (from an archive).
    public convenience init?(data: Data, fileExtension: String, loop: Bool = false) {
        let ext = fileExtension.lowercased()
        if ext == "ogv" || ext == "ogg" {
            let handle = data.withUnsafeBytes { bytes in
                shiori_theora_open(bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            guard let handle else { return nil }
            self.init(decoder: .theora(handle), audio: nil, memory: nil, loop: loop)
        } else if ext == "mpg" || ext == "mpeg" || ext == "m1v" {
            // pl_mpeg reads memory in place; keep one copy alive for both readers.
            let memory = UnsafeMutableRawPointer.allocate(byteCount: max(1, data.count), alignment: 16)
            data.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            let bytes = memory.assumingMemoryBound(to: UInt8.self)
            guard let video = plm_create_with_memory(bytes, data.count, 0) else {
                memory.deallocate()
                return nil
            }
            self.init(decoder: .mpeg(video), audio: plm_create_with_memory(bytes, data.count, 0), memory: memory, loop: loop)
        } else {
            return nil
        }
    }

    /// A video read from disk as it plays (loose movie files can be hundreds of MB).
    public convenience init?(url: URL, loop: Bool = false) {
        let ext = url.pathExtension.lowercased()
        if ext == "mpg" || ext == "mpeg" || ext == "m1v" {
            guard let video = plm_create_with_filename(url.path) else { return nil }
            self.init(decoder: .mpeg(video), audio: plm_create_with_filename(url.path), memory: nil, loop: loop)
        } else {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
            self.init(data: data, fileExtension: ext, loop: loop)
        }
    }

    private init?(decoder: Decoder, audio: OpaquePointer?, memory: UnsafeMutableRawPointer?, loop: Bool) {
        self.decoder = decoder
        self.memory = memory
        self.loop = loop
        switch decoder {
        case let .theora(handle):
            width = Int(shiori_theora_width(handle))
            height = Int(shiori_theora_height(handle))
            frameRate = shiori_theora_fps(handle)
            hasAudio = false
            audioSampleRate = 0
            audioDecoder = nil
            if let audio { plm_destroy(audio) }
        case let .mpeg(handle):
            plm_set_audio_enabled(handle, 0)
            plm_set_loop(handle, loop ? 1 : 0)
            width = Int(plm_get_width(handle))
            height = Int(plm_get_height(handle))
            frameRate = plm_get_framerate(handle)
            if let audio, plm_get_num_audio_streams(audio) > 0 {
                plm_set_video_enabled(audio, 0)
                plm_set_loop(audio, loop ? 1 : 0)
                audioDecoder = audio
                audioSampleRate = Int(plm_get_samplerate(audio))
                hasAudio = true
            } else {
                if let audio { plm_destroy(audio) }
                audioDecoder = nil
                audioSampleRate = 0
                hasAudio = false
            }
        }
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            Self.destroy(decoder)
            if let audioDecoder { plm_destroy(audioDecoder) }
            memory?.deallocate()
            return nil
        }
        // BT.601, video range: what both codecs use for SD-era tooling and these games.
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        // ITU-R BT.601 (the SDK's kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, spelled out for Swift 6).
        var matrix = vImage_YpCbCrToARGBMatrix(Yp: 1, Cr_R: 1.402, Cr_G: -0.714136, Cb_G: -0.344136, Cb_B: 1.772)
        vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix, &range, &conversion,
                                                      kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
    }

    deinit {
        Self.destroy(decoder)
        if let audioDecoder { plm_destroy(audioDecoder) }
        memory?.deallocate()
    }

    private static func destroy(_ decoder: Decoder) {
        switch decoder {
        case let .theora(handle): shiori_theora_close(handle)
        case let .mpeg(handle): plm_destroy(handle)
        }
    }

    public var duration: Double? {
        if case let .mpeg(handle) = decoder { return plm_get_duration(handle) * 1000 }
        return nil
    }

    /// Advances to the frame for clock `time` (ms). Returns whether `image` changed.
    @discardableResult
    public func update(time: Double) -> Bool {
        guard !isFinished else { return false }
        if startTime == nil { startTime = time }
        var target = Int(((time - startTime!) * frameRate / 1000).rounded(.down))
        // Far behind (the clock jumped: skip mode, a paused app): carry on from the next
        // frame instead of decoding everything in between.
        if target - framesDecoded > Int(frameRate) {
            startTime = time - Double(framesDecoded) * 1000 / frameRate
            target = framesDecoded
        }
        var planes: ShioriPlanes?
        // Decode up to the frame due now; only the last one is converted.
        while framesDecoded <= target {
            guard let next = decodeFrame() else {
                // Theora loops by starting over (pl_mpeg loops by itself).
                if loop, case let .theora(handle) = decoder, framesDecoded > 0 {
                    shiori_theora_rewind(handle)
                    startTime = time
                    framesDecoded = 0
                    target = 0
                    continue
                }
                isFinished = true
                break
            }
            planes = next
            framesDecoded += 1
        }
        guard let planes else { return false }
        // The mask follows frame for frame.
        mask?.advance(toFrame: framesDecoded)
        return show(planes)
    }

    /// Mask videos: the luma of the current frame, kept for the colour video to use.
    private var lumaFrame: (data: [UInt8], stride: Int)?

    func advance(toFrame target: Int) {
        var latest: ShioriPlanes?
        while framesDecoded < target {
            guard let next = decodeFrame() else {
                if case let .theora(handle) = decoder {
                    shiori_theora_rewind(handle)
                    framesDecoded = 0
                    continue
                }
                break
            }
            latest = next
            framesDecoded += 1
        }
        if let latest {
            let count = Int(latest.y_stride) * height
            lumaFrame = (Array(UnsafeBufferPointer(start: latest.y, count: count)), Int(latest.y_stride))
        }
    }

    private func decodeFrame() -> ShioriPlanes? {
        switch decoder {
        case let .theora(handle):
            var planes = ShioriPlanes()
            return shiori_theora_next(handle, &planes) != 0 ? planes : nil
        case let .mpeg(handle):
            guard let frame = plm_decode_video(handle)?.pointee else { return nil }
            return ShioriPlanes(y: frame.y.data, cb: frame.cb.data, cr: frame.cr.data,
                                y_stride: Int32(frame.y.width), c_stride: Int32(frame.cb.width),
                                width: Int32(frame.width), height: Int32(frame.height))
        }
    }

    private func show(_ planes: ShioriPlanes) -> Bool {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let converted: vImage_Error = pixels.withUnsafeMutableBytes { out in
            var y = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: planes.y), height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: Int(planes.y_stride))
            var cb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: planes.cb), height: vImagePixelCount(height / 2),
                                   width: vImagePixelCount(width / 2), rowBytes: Int(planes.c_stride))
            var cr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: planes.cr), height: vImagePixelCount(height / 2),
                                   width: vImagePixelCount(width / 2), rowBytes: Int(planes.c_stride))
            var dest = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height),
                                     width: vImagePixelCount(width), rowBytes: bytesPerRow)
            // ARGB out in B, G, R, A byte order: little-endian 32-bit with alpha first.
            let permute: [UInt8] = [3, 2, 1, 0]
            return vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &cb, &cr, &dest, &conversion, permute, 255,
                                                          vImage_Flags(kvImageNoFlags))
        }
        guard converted == kvImageNoError else { return false }
        var alpha = CGImageAlphaInfo.noneSkipFirst
        if let luma = mask?.lumaFrame, mask?.width == width, mask?.height == height {
            // Alpha from the mask's brightness (full range), then premultiplied.
            pixels.withUnsafeMutableBytes { out in
                let bytes = out.bindMemory(to: UInt8.self)
                for y in 0 ..< height {
                    let row = y * bytesPerRow, maskRow = y * luma.stride
                    for x in 0 ..< width { bytes[row + x * 4 + 3] = luma.data[maskRow + x] }
                }
                var buffer = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: bytesPerRow)
                vImagePremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            }
            alpha = .premultipliedFirst
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return false }
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        return image != nil
    }

    /// MPEG audio decoded so far up to `seconds` into the movie: interleaved stereo floats
    /// at `audioSampleRate`, each sample returned once. Empty when there's nothing new.
    public func audio(upTo seconds: Double) -> [Float] {
        guard let audioDecoder else { return [] }
        var result: [Float] = []
        while audioDecodedSeconds < seconds, let samples = plm_decode_audio(audioDecoder) {
            let frame = samples.pointee
            let count = Int(frame.count) * 2
            withUnsafeBytes(of: frame.interleaved) { bytes in
                result.append(contentsOf: bytes.bindMemory(to: Float.self).prefix(count))
            }
            audioDecodedSeconds = frame.time + Double(frame.count) / Double(max(1, audioSampleRate))
        }
        return result
    }
}
