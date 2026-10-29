import XCTest
@testable import EdgeLink

final class ConnectFailureTests: XCTestCase {
    func testRoutingErrorsAreUnreachable() {
        for code in [EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN] {
            XCTAssertEqual(ConnectFailure(errno: code), .unreachable)
        }
    }

    func testRefusedAndTimedOutAreTheirOwn() {
        XCTAssertEqual(ConnectFailure(errno: ECONNREFUSED), .refused)
        XCTAssertEqual(ConnectFailure(errno: ETIMEDOUT), .timedOut)
    }

    func testOtherErrorsSayNothing() {
        XCTAssertEqual(ConnectFailure(errno: EPERM), .other)
        XCTAssertNil(ConnectFailure.other.message(for: "acruz-mac"))
    }

    func testMessagesNameTheMacAndWhatToCheck() {
        let unreachable = ConnectFailure.unreachable.message(for: "acruz-mac")
        XCTAssertTrue(unreachable?.contains("acruz-mac") == true)
        XCTAssertTrue(unreachable?.contains("VPN") == true)
        XCTAssertTrue(ConnectFailure.refused.message(for: "acruz-mac")?.contains("EdgeDeck running") == true)
        XCTAssertTrue(ConnectFailure.timedOut.message(for: "acruz-mac")?.contains("firewall") == true)
    }
}
