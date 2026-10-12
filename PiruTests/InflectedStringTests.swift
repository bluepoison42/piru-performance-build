import Foundation
import Testing
@testable import Piru

@Suite("InflectedString")
struct InflectedStringTests {
    private let english = Locale(identifier: "en_US")

    @Test
    func `Inflection markup resolves to agreeing English`() {
        let count = 2
        #expect(String(inflecting: "^[\(count) item](inflect: true)", locale: english) == "2 items")
        let one = 1
        #expect(String(inflecting: "^[\(one) item](inflect: true)", locale: english) == "1 item")
    }

    @Test
    func `No markup survives into the string`() {
        let count = 3
        let text = String(inflecting: "^[\(count) item](inflect: true), all logged today", locale: english)
        #expect(text == "3 items, all logged today")
        #expect(!text.contains("inflect"))
    }
}
