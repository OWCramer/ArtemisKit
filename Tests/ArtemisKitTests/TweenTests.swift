import Testing
@testable import ArtemisKit

@Suite struct TweenTests {
    private func tag(_ pairs: [String: String]) -> ArtemisTag {
        ArtemisTag(name: "lytween", attributes: pairs, order: pairs.keys.sorted())
    }

    @Test func easingsMatchTheirEnds() {
        for curve in ["quad", "cubic", "quart", "quint", "expo", "circ", "sine", "back", "elastic", "bounce"] {
            for direction in ["easein", "easeout", "easeinout"] {
                let name = "\(direction)_\(curve)"
                #expect(abs(ArtemisTween.eased(0, name)) < 1e-9, "\(name) at 0")
                #expect(abs(ArtemisTween.eased(1, name) - 1) < 1e-9, "\(name) at 1")
            }
        }
        // Not linear: easein_quad at the midpoint is a quarter.
        #expect(abs(ArtemisTween.eased(0.5, "easein_quad") - 0.25) < 1e-9)
    }

    @Test func yoyoSwapsOnRepeats() {
        let stage = ArtemisStage(width: 100, height: 100) { _ in nil }
        stage.ensureLayer("1")
        _ = stage.tween(tag(["id": "1", "param": "left", "from": "0", "to": "100", "time": "100", "yoyo": "2"]), now: 0)
        stage.update(time: 150)
        #expect(stage.layer("1")?.left == 50)
        stage.update(time: 400)
        #expect(stage.layer("1")?.left == 0)
        #expect(stage.tweens.isEmpty)
    }

    @Test func tweenSetsRunInOrder() {
        let stage = ArtemisStage(width: 100, height: 100) { _ in nil }
        stage.ensureLayer("1")
        stage.beginTweenSet(now: 0)
        _ = stage.tween(tag(["id": "1", "param": "left", "from": "0", "to": "100", "time": "100"]), now: 0)
        _ = stage.tween(tag(["id": "1", "param": "left", "from": "100", "to": "0", "time": "100"]), now: 0)
        stage.endTweenSet()
        stage.update(time: 50)
        #expect(stage.layer("1")?.left == 50)
        stage.update(time: 150)
        #expect(stage.layer("1")?.left == 50)
        stage.update(time: 300)
        #expect(stage.layer("1")?.left == 0)
    }
}
