import CoreGraphics
import CoreText
import Foundation

/// Artemis message layers: named text areas (`adv`, `novel`, `name`, ...) chosen with
/// `[chgmsg id=...]`, laid out by `[font ...]`, filled by prose and `[print]`, cleared by `[rp]`.
public final class ArtemisMessages {
    public struct Font: Equatable, Codable {
        public var face: String?
        public var left: Double = 0
        public var top: Double = 0
        public var width: Double = 800
        public var height: Double = 200
        public var size: Double = 28
        public var color: UInt32 = 0xFFFFFF
        public var shadowColor: UInt32 = 0x000000
        public var outlineColor: UInt32 = 0x000000
        public var outline = false
        public var shadow = false
        public var kerning: Double = 0
        /// Extra space between lines (Artemis `spacemiddle`).
        public var lineSpacing: Double = 0
    }

    public final class Layer {
        public let id: String
        public var font = Font()
        public var text = ""
        public var visible = true
        /// `[sceout]`: the page is hidden but kept, until `[scein]` (or a new page).
        public var pageHidden = false
        /// Characters revealed so far (typewriter); `text.count` when complete.
        public var revealed: Double = 0
        /// Milliseconds per character (`[scetween mode=add type=in delay=...]`); 0 = instant.
        public var charDelay: Double = 30
        public var isRevealing: Bool { revealed < Double(text.count) }
        /// Bumped whenever the rendered text would change.
        public internal(set) var revision = 0

        init(id: String) { self.id = id }
    }

    public private(set) var layers: [String: Layer] = [:]
    private var stack: [String] = []
    public private(set) var current = "default"
    /// Bumped on any change, so presenters can redraw.
    public private(set) var revision = 0
    public var defaultFont = Font()

    public init() {}

    public func layer(_ id: String) -> Layer {
        if let layer = layers[id] { return layer }
        let layer = Layer(id: id)
        layer.font = defaultFont
        layers[id] = layer
        return layer
    }

    public var currentLayer: Layer { layer(current) }

    var stackSnapshot: [String] { stack }

    func resetLayers() {
        layers.removeAll()
        stack.removeAll()
        current = "default"
        revision += 1
    }

    func restoreStack(current: String, stack: [String]) {
        self.current = current
        self.stack = stack
        revision += 1
    }

    /// `[chgmsg id=...]` (pushes) and `[/chgmsg]` (pops).
    /// `stack="0"` switches without remembering the previous layer.
    public func change(to id: String?, push: Bool = true) {
        if let id {
            if push { stack.append(current) }
            current = id
            _ = layer(id)
        } else if let previous = stack.popLast() {
            current = previous
        }
    }

    public func setFont(_ tag: ArtemisTag, defaults: Bool = false) {
        var font = defaults ? defaultFont : currentLayer.font
        if let face = tag["face"] { font.face = face }
        font.left = tag.number("left", default: font.left)
        font.top = tag.number("top", default: font.top)
        font.width = tag.number("width", default: font.width)
        font.height = tag.number("height", default: font.height)
        font.size = tag.number("size", default: font.size)
        font.kerning = tag.number("kerning", default: font.kerning)
        font.lineSpacing = tag.number("spacemiddle", default: font.lineSpacing)
        if let color = tag["color"] { font.color = Self.rgb(color) }
        if let color = tag["shadowcolor"] { font.shadowColor = Self.rgb(color) }
        if let color = tag["outlinecolor"] { font.outlineColor = Self.rgb(color) }
        if let style = tag["style"] {
            font.outline = style.contains("outline")
            font.shadow = style.contains("shadow")
        }
        if defaults {
            defaultFont = font
        } else {
            currentLayer.font = font
            touch(currentLayer)
        }
    }

    public func append(_ text: String) {
        let layer = currentLayer
        layer.text += text
        touch(layer)
    }

    public func clear(_ id: String? = nil) {
        let layer = id.map(self.layer) ?? currentLayer
        guard !layer.text.isEmpty || layer.pageHidden else { return }
        layer.text = ""
        layer.revealed = 0
        layer.pageHidden = false
        touch(layer)
    }

    /// `[sceout]` / `[scein]` on the current layer.
    public func setPageHidden(_ hidden: Bool) {
        let layer = currentLayer
        guard layer.pageHidden != hidden else { return }
        layer.pageHidden = hidden
        touch(layer)
    }

    /// Advances every layer's reveal by `ms`. Returns whether anything is still revealing.
    @discardableResult
    func advanceReveal(by ms: Double, instant: Bool) -> Bool {
        var revealing = false
        for layer in layers.values where layer.isRevealing {
            if instant || layer.charDelay <= 0 {
                layer.revealed = Double(layer.text.count)
            } else {
                layer.revealed = min(Double(layer.text.count), layer.revealed + ms / layer.charDelay)
            }
            revealing = revealing || layer.isRevealing
        }
        return revealing
    }

    public var isRevealing: Bool { layers.values.contains { $0.isRevealing && $0.visible && !$0.pageHidden } }

    func revealAll() { advanceReveal(by: 0, instant: true) }

    private func touch(_ layer: Layer) {
        layer.revision += 1
        revision += 1
    }

    static func rgb(_ text: String) -> UInt32 {
        UInt32(text.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFFFF
    }
}

/// Draws message text with the game's own fonts (registered from its files).
public final class ArtemisTextRenderer {
    private var fonts: [String: CTFontDescriptor] = [:]
    private let fontData: (String) -> Data?

    public init(fontData: @escaping (String) -> Data?) {
        self.fontData = fontData
    }

    private func font(_ spec: ArtemisMessages.Font) -> CTFont {
        if let face = spec.face {
            let key = face
            if fonts[key] == nil {
                for candidate in [face, face + ".ttf", face + ".otf", face + ".ttc"] {
                    if let data = fontData(candidate),
                       let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
                        fonts[key] = descriptor
                        break
                    }
                }
            }
            if let descriptor = fonts[key] { return CTFontCreateWithFontDescriptor(descriptor, spec.size, nil) }
        }
        return CTFontCreateWithName("Hiragino Sans" as CFString, spec.size, nil)
    }

    /// Draws `layer`'s text into `context` (top-left origin, stage pixels).
    public func draw(_ layer: ArtemisMessages.Layer, in context: CGContext) {
        guard layer.visible, !layer.pageHidden, !layer.text.isEmpty else { return }
        let spec = layer.font
        let ctFont = font(spec)
        func color(_ rgb: UInt32) -> CGColor {
            CGColor(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: 1)
        }
        let paragraph: CTParagraphStyle = {
            var spacing = CGFloat(max(0, spec.lineSpacing + spec.size * 0.25))
            return withUnsafeBytes(of: &spacing) { bytes in
                var settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: bytes.baseAddress!)]
                return CTParagraphStyleCreate(&settings, settings.count)
            }
        }()
        func attributed(_ fill: CGColor, strokeWidth: Double?, strokeColor: CGColor?) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
                NSAttributedString.Key(kCTKernAttributeName as String): spec.kerning,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]
            if let strokeWidth, let strokeColor {
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
            }
            return NSAttributedString(string: layer.text, attributes: attributes)
        }
        let rect = CGRect(x: spec.left, y: spec.top, width: spec.width, height: spec.height + spec.size)
        func drawText(_ string: NSAttributedString, offset: CGSize) {
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            context.saveGState()
            // CoreText draws bottom-up: flip within the text rect.
            context.translateBy(x: rect.minX + offset.width, y: rect.maxY + offset.height)
            context.scaleBy(x: 1, y: -1)
            let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
        if spec.shadow {
            drawText(attributed(color(spec.shadowColor), strokeWidth: spec.outline ? -18 : nil, strokeColor: color(spec.shadowColor)),
                     offset: CGSize(width: 2, height: 2))
        }
        if spec.outline {
            drawText(attributed(color(spec.outlineColor), strokeWidth: 18, strokeColor: color(spec.outlineColor)), offset: .zero)
        }
        drawText(attributed(color(spec.color), strokeWidth: nil, strokeColor: nil), offset: .zero)
    }

    /// Rectangles (stage pixels, top-left origin) covering the first `count` characters, for
    /// revealing text gradually with a mask over a fully drawn line.
    public func revealRects(for layer: ArtemisMessages.Layer, count: Int) -> [CGRect] {
        let spec = layer.font
        let string = NSAttributedString(string: layer.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(spec),
            NSAttributedString.Key(kCTKernAttributeName as String): spec.kerning,
        ])
        let rect = CGRect(x: spec.left, y: spec.top, width: spec.width, height: spec.height + spec.size)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let target = (layer.text as NSString).length >= 0 ? utf16Offset(layer.text, characters: count) : 0
        var rects: [CGRect] = []
        let lineHeight = spec.size * 1.6
        for (line, origin) in zip(lines, origins) {
            let range = CTLineGetStringRange(line)
            guard range.location < target else { break }
            let end = min(target, range.location + range.length)
            let x = end >= range.location + range.length ? CTLineGetTypographicBounds(line, nil, nil, nil)
                : CTLineGetOffsetForStringIndex(line, end, nil)
            // CoreText origins are bottom-up within the text rect.
            let top = rect.minY + (rect.height - origin.y) - spec.size * 1.15
            rects.append(CGRect(x: rect.minX - 8, y: top - 6, width: x + 16, height: lineHeight + 6))
        }
        return rects
    }

    private func utf16Offset(_ text: String, characters: Int) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(characters, text.count))
        return text[..<index].utf16.count
    }

    /// The layer's text as a transparent stage-sized image (for presenters that composite).
    public func image(for layer: ArtemisMessages.Layer, stageWidth: Double, stageHeight: Double, scale: Double = 1) -> CGImage? {
        let w = Int(stageWidth * scale), h = Int(stageHeight * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: scale, y: -scale)
        draw(layer, in: context)
        return context.makeImage()
    }
}
