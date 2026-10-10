import CoreGraphics
import CoreText
import Foundation

/// Artemis message layers: named text areas (`adv`, `novel`, `name`, ...) chosen with
/// `[chgmsg id=...]`, laid out by `[font ...]`, filled by prose and `[print]`, cleared by `[rp]`.
/// A page is a list of runs, each with the font in force when it was written, so
/// `[font color=...]word[/font]` colours just that word; runs carry ruby and links too.
public final class ArtemisMessages {
    /// The `[font]` settings (font.txt). Defaults are the engine's.
    public struct Font: Equatable, Codable, Sendable {
        public var face: String?
        public var rubyFace: String?
        public var left: Double = 0
        public var top: Double = 0
        public var width: Double = 640
        public var height: Double = 480
        public var size: Double = 24
        public var color: UInt32 = 0xFFFFFF
        public var shadowColor: UInt32 = 0x000000
        public var outlineColor: UInt32 = 0x000000
        /// Outline width and drop-shadow distance in pixels (0 = none).
        public var outlineWidth: Double = 0
        public var shadowDistance: Double = 0
        public var kerning: Double = 0
        /// Gap between the ruby and the text (Artemis `spacemiddle`).
        public var lineSpacing: Double = 0
        /// Gap above the ruby (`spacetop`) and below the text (`spacebottom`).
        public var spaceTop: Double = 0
        public var spaceBottom: Double = 0
        /// Ruby band height (`rubysize`); reserved above every line, ruby or not.
        public var rubySize: Double = 8
        /// left, center or right (`equalize` lays out as left).
        public var align = "left"
        /// 0...255 per character.
        public var alpha: Double = 255
        public var underline = false
        public var strikeout = false
        /// `overflow=1`: text past `height` just runs on (0: a click wait and a new page).
        public var allowOverflow = false

        public var outline: Bool { outlineWidth > 0 }
        public var shadow: Bool { shadowDistance > 0 }

        public init() {}

        /// Saves from before a field existed still load, with its default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            face = try c.decodeIfPresent(String.self, forKey: .face)
            rubyFace = try c.decodeIfPresent(String.self, forKey: .rubyFace)
            left = try c.decodeIfPresent(Double.self, forKey: .left) ?? 0
            top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 640
            height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 480
            size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 24
            color = try c.decodeIfPresent(UInt32.self, forKey: .color) ?? 0xFFFFFF
            shadowColor = try c.decodeIfPresent(UInt32.self, forKey: .shadowColor) ?? 0
            outlineColor = try c.decodeIfPresent(UInt32.self, forKey: .outlineColor) ?? 0
            outlineWidth = try c.decodeIfPresent(Double.self, forKey: .outlineWidth)
                ?? ((try legacy.decodeIfPresent(Bool.self, forKey: .outline)) == true ? 2 : 0)
            shadowDistance = try c.decodeIfPresent(Double.self, forKey: .shadowDistance)
                ?? ((try legacy.decodeIfPresent(Bool.self, forKey: .shadow)) == true ? 2 : 0)
            kerning = try c.decodeIfPresent(Double.self, forKey: .kerning) ?? 0
            lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0
            spaceTop = try c.decodeIfPresent(Double.self, forKey: .spaceTop) ?? 0
            spaceBottom = try c.decodeIfPresent(Double.self, forKey: .spaceBottom) ?? 0
            rubySize = try c.decodeIfPresent(Double.self, forKey: .rubySize) ?? 8
            align = try c.decodeIfPresent(String.self, forKey: .align) ?? "left"
            alpha = try c.decodeIfPresent(Double.self, forKey: .alpha) ?? 255
            underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
            strikeout = try c.decodeIfPresent(Bool.self, forKey: .strikeout) ?? false
            allowOverflow = try c.decodeIfPresent(Bool.self, forKey: .allowOverflow) ?? false
        }

        private enum LegacyKeys: String, CodingKey { case outline, shadow }

        /// Height of one line: ruby band and gaps (font.txt) around the text row, which is
        /// the font's own line height (see ArtemisTextRenderer.lineMetrics).
        func linePitch(textHeight: Double) -> Double {
            let pitch = spaceTop + rubySize + lineSpacing + textHeight + spaceBottom
            return pitch > 0 ? pitch : textHeight
        }
    }

    /// A stretch of text written with one font (and ruby or link, when set).
    public struct Run: Equatable, Codable, Sendable {
        public var text: String
        public var font: Font
        /// `[ruby text=...]` over this run.
        public var ruby: String?
        /// Index into the layer's links (`[link]...[/link]`).
        public var link: Int?
    }

    /// `[link file= label=]`: a stretch of text that jumps when tapped.
    public struct Link: Equatable, Codable, Sendable {
        public var attributes: [String: String]
        public var enabled = true
    }

    public final class Layer {
        public let id: String
        /// The font for text written next (and the page's layout when it has no text yet).
        public var font = Font()
        public internal(set) var runs: [Run] = []
        public internal(set) var links: [Link] = []
        /// `[font]` pushes the previous setting here; `[/font]` pops it.
        var fontStack: [Font] = []
        /// Ruby text for the run being written (`[ruby]` ... `[/ruby]`).
        var activeRuby: String?
        /// Link the text being written belongs to (`[link]` ... `[/link]`).
        var activeLink: Int?
        public var visible = true
        /// `[chgmsg layered=1]`: drawn in the layer tree (at the stage layer with this id).
        public internal(set) var layered = false
        /// `[lyprop id="~<layer>"]`: the page moved and faded as a whole.
        public var offsetX: Double = 0
        public var offsetY: Double = 0
        public var alpha: Double = 255
        /// `[sceout]`: the page is hidden but kept, until `[scein]` (or a new page).
        public var pageHidden = false
        /// Characters revealed so far (typewriter); `text.count` when complete.
        public var revealed: Double = 0
        /// Milliseconds per character (`[scetween mode=add type=in delay=...]`); 0 = instant.
        public var charDelay: Double = 30
        public var isRevealing: Bool { revealed < Double(text.count) }
        /// Bumped whenever the rendered text would change.
        public internal(set) var revision = 0

        /// The page's text. Setting it replaces the runs with one run in the current font.
        public var text: String {
            get { runs.map(\.text).joined() }
            set { runs = newValue.isEmpty ? [] : [Run(text: newValue, font: font)] }
        }

        /// The settings the page is laid out with: its first run's, or the current font.
        public var layoutFont: Font { runs.first?.font ?? font }

        init(id: String) { self.id = id }

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            if var last = runs.last, last.font == font, last.ruby == nil, activeRuby == nil, last.link == activeLink {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(text: text, font: font, ruby: activeRuby, link: activeLink))
            }
        }

        /// Cuts the page at a UTF-16 offset; returns the text removed.
        func truncate(atUTF16 offset: Int) -> String {
            var kept: [Run] = []
            var removed = ""
            var location = 0
            for run in runs {
                let length = (run.text as NSString).length
                if location + length <= offset {
                    kept.append(run)
                } else if location >= offset {
                    removed += run.text
                } else {
                    let split = offset - location
                    var head = run
                    head.text = (run.text as NSString).substring(to: split)
                    kept.append(head)
                    removed += (run.text as NSString).substring(from: split)
                }
                location += length
            }
            runs = kept
            revealed = min(revealed, Double(text.count))
            return removed
        }

        func clearPage() {
            runs = []
            links = []
            activeLink = nil
            activeRuby = nil
            revealed = 0
            pageHidden = false
        }
    }

    public private(set) var layers: [String: Layer] = [:]
    private var stack: [String] = []
    public private(set) var current = "default"
    /// Bumped on any change, so presenters can redraw.
    public private(set) var revision = 0
    public var defaultFont = Font()
    /// `[indent pair="「」『』"]`: opening -> closing characters for hanging indents.
    public var indentPairs: [Character: Character] = [:]
    /// `[indent nest=1]`: indent again for every opening character.
    public var indentNest = false

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

    /// `[font]` / `[fontdefault]`.
    public func setFont(_ tag: ArtemisTag, defaults: Bool = false) {
        var font = defaults ? defaultFont : currentLayer.font
        if let face = tag["face"] { font.face = face }
        if let face = tag["rubyface"] { font.rubyFace = face }
        font.left = tag.number("left", default: font.left)
        font.top = tag.number("top", default: font.top)
        font.width = tag.number("width", default: font.width)
        font.height = tag.number("height", default: font.height)
        font.size = tag.number("size", default: font.size)
        font.kerning = tag.number("kerning", default: font.kerning)
        font.lineSpacing = tag.number("spacemiddle", default: font.lineSpacing)
        font.spaceTop = tag.number("spacetop", default: font.spaceTop)
        font.spaceBottom = tag.number("spacebottom", default: font.spaceBottom)
        font.rubySize = tag.number("rubysize", default: font.rubySize)
        font.alpha = tag.number("alpha", default: font.alpha)
        font.outlineWidth = tag.number("outline", default: font.outlineWidth)
        font.shadowDistance = tag.number("shadow", default: font.shadowDistance)
        if let align = tag["align"] { font.align = align.lowercased() }
        if let overflow = tag["overflow"] { font.allowOverflow = overflow == "1" }
        if let color = tag["color"] { font.color = Self.rgb(color) }
        if let color = tag["shadowcolor"] { font.shadowColor = Self.rgb(color) }
        if let color = tag["outlinecolor"] { font.outlineColor = Self.rgb(color) }
        if let style = tag["style"]?.lowercased() {
            // Older engines took outline and shadow as styles.
            if style.contains("outline") { font.outlineWidth = max(font.outlineWidth, 3) }
            if style.contains("shadow") { font.shadowDistance = max(font.shadowDistance, 2) }
            font.underline = style.contains("underline")
            font.strikeout = style.contains("strikeout")
        }
        if defaults {
            defaultFont = font
        } else {
            let layer = currentLayer
            if tag["stack"] != "0" { layer.fontStack.append(layer.font) }
            layer.font = font
            touch(layer)
        }
    }

    /// `[chgmsg layered=]` for a layer.
    public func setLayered(_ id: String, _ layered: Bool) {
        let layer = self.layer(id)
        layer.layered = layered
        touch(layer)
    }

    /// `[/font]`: back to the font before the last `[font]`.
    public func popFont() {
        let layer = currentLayer
        guard let previous = layer.fontStack.popLast() else { return }
        layer.font = previous
        touch(layer)
    }

    /// `[fontinit]`: the default font, and an empty font stack.
    public func resetFont() {
        let layer = currentLayer
        layer.font = defaultFont
        layer.fontStack = []
        touch(layer)
    }

    public func append(_ text: String) {
        let layer = currentLayer
        layer.append(text)
        touch(layer)
    }

    /// `[ruby text=]` / `[/ruby]`.
    public func setRuby(_ text: String?) {
        currentLayer.activeRuby = text
    }

    /// `[link ...]`: following text belongs to a new link; `[/link]` (nil) ends it.
    public func beginLink(_ attributes: [String: String]?) {
        let layer = currentLayer
        if let attributes {
            layer.links.append(Link(attributes: attributes))
            layer.activeLink = layer.links.count - 1
        } else {
            layer.activeLink = nil
        }
    }

    /// `[linkenable]` / `[linkdisable]` for the current layer's links.
    public func setLinksEnabled(_ enabled: Bool) {
        let layer = currentLayer
        for i in layer.links.indices { layer.links[i].enabled = enabled }
        touch(layer)
    }

    public func clear(_ id: String? = nil) {
        let layer = id.map(self.layer) ?? currentLayer
        guard !layer.runs.isEmpty || layer.pageHidden || !layer.links.isEmpty else { return }
        layer.clearPage()
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
            let count = Double(layer.text.count)
            if instant || layer.charDelay <= 0 {
                layer.revealed = count
            } else {
                layer.revealed = min(count, layer.revealed + ms / layer.charDelay)
            }
            revealing = revealing || layer.isRevealing
        }
        return revealing
    }

    public var isRevealing: Bool { layers.values.contains { $0.isRevealing && $0.visible && !$0.pageHidden } }

    func revealAll() { advanceReveal(by: 0, instant: true) }

    func touch(_ layer: Layer) {
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
    /// Indent pairs, from the messages (`[indent]`).
    public var indentPairs: () -> [Character: Character] = { [:] }
    /// The newer generation (compiled `.asb` scripts, NUKITASHI) tightens only full-width
    /// characters with `kerning`, and its lines are the font's win (not typographic) height:
    /// NUKITASHI's English, at 30 px with kerning -4, sets Latin at its natural advance and
    /// 39 px lines in the official Steam screenshots.
    public var newerGeneration = false

    public init(fontData: @escaping (String) -> Data?) {
        self.fontData = fontData
    }

    private func font(_ face: String?, size: Double) -> CTFont {
        if let face {
            if fonts[face] == nil {
                for candidate in [face, face + ".ttf", face + ".otf", face + ".ttc"] {
                    if let data = fontData(candidate),
                       let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
                        fonts[face] = descriptor
                        break
                    }
                }
            }
            if let descriptor = fonts[face] {
                let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
                // The older generation takes `size` as Windows' cell height (a positive GDI
                // lfHeight: ascent plus descent), so the glyphs are smaller than `size` px:
                // Memory's Dogma's official screenshots set its English lines at Nasu ~29 px
                // for size 40. The newer generation's size is the em (NUKITASHI's screenshots).
                guard !newerGeneration, let cell = Self.winCellHeight(font), cell > 0 else { return font }
                return CTFontCreateWithFontDescriptor(descriptor, size * size / cell, nil)
            }
            // An OS font by name (the engine falls back to these on iOS too).
            let system = CTFontCreateWithName(face as CFString, size, nil)
            if (CTFontCopyPostScriptName(system) as String).lowercased().contains(face.lowercased().prefix(4)) { return system }
        }
        return CTFontCreateWithName("HiraginoSans-W3" as CFString, size, nil)
    }

    private func font(_ spec: ArtemisMessages.Font) -> CTFont { font(spec.face, size: spec.size) }

    /// Windows' line height (usWinAscent + usWinDescent) for the font at its size.
    static func winCellHeight(_ font: CTFont) -> Double? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 78 else { return nil }
        func uint16(_ offset: Int) -> Double { Double(UInt16(table[table.startIndex + offset]) << 8 | UInt16(table[table.startIndex + offset + 1])) }
        let unitsPerEm = Double(CTFontGetUnitsPerEm(font))
        let sum = uint16(74) + uint16(76)
        guard unitsPerEm > 0, sum > 0 else { return nil }
        return sum * CTFontGetSize(font) / unitsPerEm
    }

    /// The text row's ascent and height. With `win`, Windows' cell (usWinAscent and
    /// usWinDescent), which both generations use; otherwise the OS/2 typographic metrics.
    /// Falls back to CoreText's metrics for fonts without an OS/2 table.
    static func lineMetrics(_ font: CTFont, size: Double, win: Bool = false) -> (ascent: Double, height: Double) {
        if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 74 {
            func int16(_ offset: Int) -> Double {
                Double(Int16(bitPattern: UInt16(table[table.startIndex + offset]) << 8 | UInt16(table[table.startIndex + offset + 1])))
            }
            let unitsPerEm = Double(CTFontGetUnitsPerEm(font))
            if win, table.count >= 78, unitsPerEm > 0 {
                let ascent = Double(UInt16(bitPattern: Int16(int16(74)))), descent = Double(UInt16(bitPattern: Int16(int16(76))))
                if ascent > 0 { return (ascent * size / unitsPerEm, (ascent + descent) * size / unitsPerEm) }
            }
            let ascender = int16(68), descender = int16(70), lineGap = int16(72)
            if unitsPerEm > 0, ascender > 0 {
                let scale = size / unitsPerEm
                return (ascender * scale, (ascender - descender + max(0, lineGap)) * scale)
            }
        }
        let ascent = CTFontGetAscent(font)
        return (ascent, ascent + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// One laid-out line: where it starts (stage pixels, top-left origin) and its text.
    struct Line {
        let line: CTLine
        /// Left edge and top of the line's box (ruby band included).
        let x: Double
        let top: Double
        let pitch: Double
        let baseline: Double
        let range: CFRange
        let width: Double
    }

    private enum Pass { case shadow, outline, fill, measure }

    private func color(_ rgb: UInt32, alpha: Double) -> CGColor {
        CGColor(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255,
                alpha: max(0, min(1, alpha / 255)))
    }

    /// The page as an attributed string for one drawing pass. Every pass has the same
    /// glyph advances, so they lay out identically.
    private func attributed(_ layer: ArtemisMessages.Layer, pass: Pass) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in layer.runs {
            let spec = run.font
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(spec),
                NSAttributedString.Key(kCTKernAttributeName as String): spec.kerning,
            ]
            let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
            switch pass {
            case .shadow:
                let shadow = spec.shadow ? color(spec.shadowColor, alpha: spec.alpha) : clear
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = shadow
                if spec.outline {
                    attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -outlineStroke(spec)
                    attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = shadow
                }
            case .outline:
                let outline = spec.outline ? color(spec.outlineColor, alpha: spec.alpha) : clear
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = outline
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = outlineStroke(spec)
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = outline
            case .fill:
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color(spec.color, alpha: spec.alpha)
                if spec.underline {
                    attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
                }
            case .measure:
                break
            }
            let piece = NSMutableAttributedString(string: run.text, attributes: attributes)
            if spec.kerning != 0 {
                // Only full-width characters are tightened (both generations: Memory's Dogma's
                // English lines are their natural width despite kerning="-3").
                var offset = 0
                for character in run.text {
                    let length = character.utf16.count
                    if !Self.isFullWidth(character) {
                        piece.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: 0, range: NSRange(location: offset, length: length))
                    }
                    offset += length
                }
            }
            result.append(piece)
        }
        return result
    }

    /// East Asian wide and full-width characters (CJK, kana, hangul, full-width forms).
    static func isFullWidth(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// CoreText stroke width (percent of the font size) for an outline `outlineWidth` px wide
    /// on each side.
    private func outlineStroke(_ spec: ArtemisMessages.Font) -> Double {
        max(1, spec.outlineWidth) * 2 / max(1, CTFontGetSize(font(spec))) * 100
    }

    /// Lays text out the engine's way: wrapped to `width`, every line `linePitch` tall,
    /// glyphs under a ruby band, aligned left, centre or right; lines that wrap inside an
    /// opening bracket (`[indent]`) hang under it.
    private func layout(_ layer: ArtemisMessages.Layer, string: NSAttributedString) -> [Line] {
        let spec = layer.layoutFont
        let ctFont = font(spec)
        let text = string.string as NSString
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = text.length
        // Both generations' text row is Windows' cell (win ascent + descent) of the font as
        // drawn; for the older one that's `size` itself.
        let (ascent, textHeight) = Self.lineMetrics(ctFont, size: CTFontGetSize(ctFont), win: true)
        let pitch = spec.linePitch(textHeight: textHeight)
        let pairs = indentPairs()
        var lines: [Line] = []
        var start = 0
        var index = 0
        var indent = 0.0
        var closing: Character?
        while start < length {
            // A new logical line (page start or after a newline) may open an indent.
            let logicalStart = start == 0 || text.character(at: start - 1) == 0x0A
            if logicalStart {
                indent = 0
                closing = nil
                if let scalar = Unicode.Scalar(text.character(at: start)), let close = pairs[Character(scalar)] {
                    let opener = CTLineCreateWithAttributedString(string.attributedSubstring(from: NSRange(location: start, length: 1)))
                    indent = CTLineGetTypographicBounds(opener, nil, nil, nil)
                    closing = close
                }
            }
            let offset = logicalStart ? 0 : indent
            let count = max(1, CTTypesetterSuggestLineBreakWithOffset(typesetter, start, max(1, spec.width - offset), offset))
            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLineWithOffset(typesetter, range, 0)
            // Trailing newlines and spaces don't count towards alignment.
            let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
            var x: Double
            switch spec.align {
            case "center": x = spec.left + (spec.width - width) / 2
            case "right": x = spec.left + spec.width - width
            default: x = spec.left + offset
            }
            x += layer.offsetX
            let top = spec.top + layer.offsetY + Double(index) * pitch
            let textTop = top + spec.spaceTop + spec.rubySize + spec.lineSpacing
            lines.append(Line(line: line, x: x, top: top, pitch: pitch, baseline: textTop + ascent, range: range, width: width))
            // The closing bracket ends the hanging indent.
            if let closing, text.substring(with: NSRange(location: start, length: count)).contains(closing) { indent = 0 }
            start += count
            index += 1
        }
        return lines
    }

    /// Draws `layer`'s text into `context` (top-left origin, stage pixels). `parity`: only the
    /// even (0) or odd (1) lines, so a reveal that reaches below one line never uncovers the
    /// next (NUKITASHI's lines overlap: its pitch is shorter than ascent plus descent).
    public func draw(_ layer: ArtemisMessages.Layer, in context: CGContext, parity: Int? = nil) {
        guard layer.visible, !layer.pageHidden, !layer.runs.isEmpty, layer.alpha > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(layer.alpha / 255)
        let all = layout(layer, string: attributed(layer, pass: .measure))
        let lines = parity.map { p in all.enumerated().filter { $0.offset % 2 == p }.map(\.element) } ?? all
        func pass(_ pass: Pass, offset: Double) {
            let string = attributed(layer, pass: pass)
            for line in lines {
                let drawn = CTLineCreateWithAttributedString(string.attributedSubstring(from: NSRange(location: line.range.location, length: line.range.length)))
                context.saveGState()
                // CoreText draws bottom-up: flip around each line's baseline.
                context.translateBy(x: line.x + offset, y: line.baseline + offset)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(drawn, context)
                context.restoreGState()
            }
        }
        let shadow = layer.runs.map(\.font.shadowDistance).max() ?? 0
        if shadow > 0 { pass(.shadow, offset: shadow) }
        if layer.runs.contains(where: { $0.font.outline }) { pass(.outline, offset: 0) }
        pass(.fill, offset: 0)
        drawRuby(layer, lines: lines, in: context)
    }

    /// Ruby text centred over each ruby run, in the ruby band above its line.
    private func drawRuby(_ layer: ArtemisMessages.Layer, lines: [Line], in context: CGContext) {
        var location = 0
        for run in layer.runs {
            let length = (run.text as NSString).length
            defer { location += length }
            guard let ruby = run.ruby, !ruby.isEmpty else { continue }
            let spec = run.font
            let rubySize = spec.rubySize > 0 ? spec.rubySize : spec.size * 0.4
            for line in lines {
                let lineEnd = line.range.location + line.range.length
                let start = max(location, line.range.location), end = min(location + length, lineEnd)
                guard start < end else { continue }
                let x0 = CTLineGetOffsetForStringIndex(line.line, start, nil)
                let x1 = CTLineGetOffsetForStringIndex(line.line, end, nil)
                var attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font(spec.rubyFace ?? spec.face, size: rubySize),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(spec.color, alpha: spec.alpha),
                ]
                if spec.outline {
                    attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -outlineStroke(spec) / 2
                    attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color(spec.outlineColor, alpha: spec.alpha)
                }
                let rubyLine = CTLineCreateWithAttributedString(NSAttributedString(string: ruby, attributes: attributes))
                let rubyWidth = CTLineGetTypographicBounds(rubyLine, nil, nil, nil)
                let rubyFont = font(spec.rubyFace ?? spec.face, size: rubySize)
                let (rubyAscent, _) = Self.lineMetrics(rubyFont, size: CTFontGetSize(rubyFont), win: true)
                context.saveGState()
                context.translateBy(x: line.x + (x0 + x1) / 2 - rubyWidth / 2, y: line.top + spec.spaceTop + rubyAscent)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(rubyLine, context)
                context.restoreGState()
            }
        }
    }

    /// Rectangles (stage pixels, top-left origin) covering characters [from, to) of the page.
    private func rects(_ layer: ArtemisMessages.Layer, lines: [Line], from: Int, to: Int) -> [CGRect] {
        var rects: [CGRect] = []
        for line in lines {
            let lineEnd = line.range.location + line.range.length
            let start = max(from, line.range.location), end = min(to, lineEnd)
            guard start < end else { continue }
            let x0 = start == line.range.location ? 0 : CTLineGetOffsetForStringIndex(line.line, start, nil)
            let x1 = end >= lineEnd ? line.width : CTLineGetOffsetForStringIndex(line.line, end, nil)
            // Down to the glyphs' real bottom: a negative spacebottom (NUKITASHI) makes the pitch
            // shorter than the descenders, which would stay hidden until the line completed.
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line.line, nil, &descent, nil)
            let outline = layer.layoutFont.outline ? layer.layoutFont.outlineWidth : 0
            let bottom = max(line.top + line.pitch, line.baseline + descent + outline)
            rects.append(CGRect(x: line.x + x0, y: line.top, width: x1 - x0, height: bottom - line.top))
        }
        return rects
    }

    /// The laid-out size of a layer's text: widest line, total height (line pitch times
    /// lines) and the last line's width (get_message_layer_width/height/line_width).
    public func measure(_ layer: ArtemisMessages.Layer) -> (width: Double, height: Double, lastLineWidth: Double) {
        guard !layer.runs.isEmpty else { return (0, 0, 0) }
        let lines = layout(layer, string: attributed(layer, pass: .measure))
        let width = lines.map(\.width).max() ?? 0
        let height = lines.last.map { $0.top + $0.pitch - layer.layoutFont.top - layer.offsetY } ?? 0
        return (width, height, lines.last?.width ?? 0)
    }

    /// Where a page overflows its box (`height`): the UTF-16 offset of the first line that
    /// doesn't fit, when there's an earlier line to keep.
    public func overflowOffset(_ layer: ArtemisMessages.Layer) -> Int? {
        let spec = layer.layoutFont
        guard !spec.allowOverflow, spec.height > 0, !layer.runs.isEmpty else { return nil }
        let lines = layout(layer, string: attributed(layer, pass: .measure))
        for (index, line) in lines.enumerated() where index > 0 {
            let textBottom = line.top + line.pitch - spec.spaceBottom
            if textBottom > spec.top + spec.height + 0.5 { return line.range.location }
        }
        return nil
    }

    /// Where the text ends: the right edge of the last character and the top of its line's
    /// text row (for the click-wait glyph).
    public func endPoint(_ layer: ArtemisMessages.Layer) -> CGPoint? {
        guard !layer.runs.isEmpty, let last = layout(layer, string: attributed(layer, pass: .measure)).last else { return nil }
        let spec = layer.layoutFont
        return CGPoint(x: last.x + last.width, y: last.top + spec.spaceTop + spec.rubySize + spec.lineSpacing)
    }

    /// Stage rectangles of each enabled link (link index, rectangle).
    public func linkRects(_ layer: ArtemisMessages.Layer) -> [(Int, CGRect)] {
        guard layer.runs.contains(where: { $0.link != nil }) else { return [] }
        let lines = layout(layer, string: attributed(layer, pass: .measure))
        var result: [(Int, CGRect)] = []
        var location = 0
        for run in layer.runs {
            let length = (run.text as NSString).length
            if let link = run.link, link < layer.links.count, layer.links[link].enabled {
                result += rects(layer, lines: lines, from: location, to: location + length).map { (link, $0) }
            }
            location += length
        }
        return result
    }

    /// Rectangles covering the first `count` characters, for revealing text gradually with
    /// a mask over a fully drawn page (margins for outlines and ruby).
    public func revealRects(for layer: ArtemisMessages.Layer, count: Int, parity: Int? = nil) -> [CGRect] {
        let target = utf16Offset(layer.text, characters: count)
        let all = layout(layer, string: attributed(layer, pass: .measure))
        let lines = parity.map { p in all.enumerated().filter { $0.offset % 2 == p }.map(\.element) } ?? all
        return rects(layer, lines: lines, from: 0, to: target).map { $0.insetBy(dx: -8, dy: -6) }
    }

    private func utf16Offset(_ text: String, characters: Int) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(characters, text.count))
        return text[..<index].utf16.count
    }

    /// The layer's text as a transparent stage-sized image (for presenters that composite).
    public func image(for layer: ArtemisMessages.Layer, stageWidth: Double, stageHeight: Double, scale: Double = 1,
                      parity: Int? = nil) -> CGImage? {
        let w = Int(stageWidth * scale), h = Int(stageHeight * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: scale, y: -scale)
        draw(layer, in: context, parity: parity)
        return context.makeImage()
    }
}
