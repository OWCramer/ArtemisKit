import Foundation
import Testing
@testable import ArtemisKit

@MainActor
struct PlutoTests {
    /// `pluto.persist` / `unpersist` round-trip what the newer generation saves: nested and
    /// shared tables, cycles, strings with any bytes, numbers, booleans.
    @Test func roundTrips() throws {
        let game = FileManager.default.temporaryDirectory.appendingPathComponent("pluto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("system"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: game) }
        let script = """
        [lua]
        local shared = { 1, 2 }
        local t = { a = "x;y:z\\0e", n = 1.5, big = 123456789012, neg = -3, yes = true, no = false,
                    list = { "p", "q" }, s1 = shared, s2 = shared, [7] = "seven" }
        t.me = t
        local u = pluto.unpersist({}, pluto.persist({}, t))
        local ok = u.a == t.a and u.n == 1.5 and u.big == 123456789012 and u.neg == -3 and u.yes == true
            and u.no == false and u.list[2] == "q" and u.s1 == u.s2 and u.s1[2] == 2 and u[7] == "seven" and u.me == u
            and pluto.unpersist({}, "") == nil and pluto.unpersist({}, "t") == nil
        e:tag{"var", name="t.ok", data=(ok and "1" or "0")}
        [/lua]
        """
        try Data(script.utf8).write(to: game.appendingPathComponent("system/first.iet"))
        let interpreter = ArtemisInterpreter(fileSystem: try ArtemisFileSystem(gameRoot: game), stageWidth: 1280, stageHeight: 720)
        try interpreter.boot("system/first.iet")
        _ = interpreter.run(maxSteps: 1000)
        #expect(interpreter.variables["t.ok"] == "1")
    }
}
