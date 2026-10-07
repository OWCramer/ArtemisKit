import Testing
@testable import ArtemisKit

@Suite struct ExpressionTests {
    private func eval(_ source: String, _ variables: [String: String] = [:]) throws -> String {
        try ArtemisExpression.evaluate(source) { variables[$0] }.text
    }

    @Test func addsNumbersAndJoinsStrings() throws {
        #expect(try eval("1 + 2") == "3")
        #expect(try eval("foo + bar", ["foo": "1", "bar": "2"]) == "3")
        #expect(try eval("foo + 'bar'", ["foo": "1"]) == "1bar")
    }

    @Test func variablesJoinAsWritten() throws {
        // Button macros build child ids this way: 100.10 must not collapse to 100.1.
        #expect(try eval("id + '.1'", ["id": "100.10"]) == "100.10.1")
        #expect(try eval("id + 1", ["id": "100.10"]) == "101.1")
    }

    @Test func wholeNumbersDivideAsIntegers() throws {
        #expect(try eval("(i - 1) / 4", ["i": "7"]) == "1")
    }
}
