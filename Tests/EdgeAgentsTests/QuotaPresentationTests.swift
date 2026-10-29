import XCTest
@testable import EdgeAgents

final class QuotaPresentationTests: XCTestCase {
    private func decode(_ json: String) throws -> AIQuotaPresentation {
        try JSONDecoder().decode([AIQuotaPresentation].self, from: Data("[\(json)]".utf8))[0]
    }

    func testEachLayoutDecodesFromItsName() throws {
        XCTAssertEqual(try decode(#""inline""#), .inline)
        XCTAssertEqual(try decode(#""split""#), .split)
        XCTAssertEqual(try decode(#""tapToFlip""#), .tapToFlip)
    }

    func testTheEarlierNameFlipMeansTheSeparateButtons() throws {
        XCTAssertEqual(try decode(#""flip""#), .split)
    }

    func testAnUnknownLayoutFallsBackToTogether() throws {
        XCTAssertEqual(try decode(#""carousel""#), .inline)
        XCTAssertEqual(try decode(#""""#), .inline)
    }

    func testItEncodesToTheNameItDecodesFrom() throws {
        for layout in [AIQuotaPresentation.inline, .split, .tapToFlip] {
            let data = try JSONEncoder().encode([layout])
            XCTAssertEqual(try JSONDecoder().decode([AIQuotaPresentation].self, from: data), [layout])
        }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([AIQuotaPresentation.tapToFlip]), as: UTF8.self), #"["tapToFlip"]"#)
    }
}
