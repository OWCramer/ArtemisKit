import Foundation

/// Everything `[save]` keeps: script position, variables (not `t.` or `g.`), the layer
/// tree, layer events, message layers, input setup and music. Lua state is not saved
/// (the engine doesn't either; games keep what they need in variables).
struct ArtemisSaveState: Codable {
    struct Frame: Codable {
        var file: String
        var pc: Int
        var locals: [String: String]
        var isMacro: Bool
        var interrupt: Bool
        var rightClick: Bool
    }

    struct Layer: Codable {
        var id: String
        var file: String?
        var color: UInt32?
        var width, height, left, top, alpha, xscale, yscale, rotate: Double
        var anchorX, anchorY: Double?
        var visible: Bool
    }

    struct Message: Codable {
        var id: String
        var font: ArtemisMessages.Font
        var text: String
        var visible: Bool
        var pageHidden: Bool
    }

    var version = 1
    var frames: [Frame]
    var variables: [String: String]
    var layers: [Layer]
    var events: [String: [String: [String: String]]]
    var messages: [Message]
    var currentMessage: String
    var messageStack: [String]
    var defaultFont: ArtemisMessages.Font
    var wait: String
    var pendingText: String?
    var keyHandlers: [String: [String: String]]
    var rightClickFile: String
    var rightClickAllowed: Bool
    var hideWindows: [String]
    var music: [String: String]?
}


extension ArtemisStage {
    func savedLayers() -> [ArtemisSaveState.Layer] {
        var result: [ArtemisSaveState.Layer] = []
        func visit(_ layer: ArtemisLayer) {
            result.append(.init(id: layer.id, file: layer.file, color: layer.color, width: layer.width, height: layer.height,
                                left: layer.left, top: layer.top, alpha: layer.alpha, xscale: layer.xscale, yscale: layer.yscale,
                                rotate: layer.rotate, anchorX: layer.anchorX, anchorY: layer.anchorY, visible: layer.visible))
            layer.children.forEach(visit)
        }
        root.children.forEach(visit)
        return result
    }

    func restore(layers: [ArtemisSaveState.Layer], events: [String: [String: [String: String]]]) {
        deleteLayer("")
        for saved in layers {
            let layer = ensureLayer(saved.id)
            layer.file = saved.file
            layer.image = saved.file.flatMap { file in
                [file, file + ".png", file + ".jpg"].lazy.compactMap { self.image($0) }.first
            }
            layer.color = saved.color
            layer.width = saved.width; layer.height = saved.height
            layer.left = saved.left; layer.top = saved.top
            layer.alpha = saved.alpha; layer.xscale = saved.xscale; layer.yscale = saved.yscale
            layer.rotate = saved.rotate; layer.anchorX = saved.anchorX; layer.anchorY = saved.anchorY
            layer.visible = saved.visible
        }
        restoreEvents(events)
    }
}

extension ArtemisMessages {
    func saved() -> ([ArtemisSaveState.Message], String, [String], Font) {
        (layers.values.map { .init(id: $0.id, font: $0.font, text: $0.text, visible: $0.visible, pageHidden: $0.pageHidden) },
         current, stackSnapshot, defaultFont)
    }

    func restore(_ messages: [ArtemisSaveState.Message], current: String, stack: [String], defaultFont: Font) {
        self.defaultFont = defaultFont
        resetLayers()
        for saved in messages {
            let layer = self.layer(saved.id)
            layer.font = saved.font
            layer.text = saved.text
            layer.visible = saved.visible
            layer.pageHidden = saved.pageHidden
            layer.revision += 1
        }
        restoreStack(current: current, stack: stack)
    }
}
