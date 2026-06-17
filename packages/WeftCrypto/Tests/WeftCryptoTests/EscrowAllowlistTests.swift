import XCTest
@testable import WeftCrypto

final class EscrowAllowlistTests: XCTestCase {
    func testShippedIsEmptyInV1() {
        // v1 ships no escrow kid until the HSM publishes one — fail closed.
        XCTAssertTrue(WeftEscrowAllowlist.shipped.isEmpty)
        XCTAssertTrue(WeftEscrowAllowlist().kids.isEmpty)
        XCTAssertFalse(WeftEscrowAllowlist().contains("anyKid"))
    }

    func testCustomAllowlistContains() {
        let a = WeftEscrowAllowlist(kids: ["escrowKidA", "escrowKidB"])
        XCTAssertTrue(a.contains("escrowKidA"))
        XCTAssertTrue(a.contains("escrowKidB"))
        XCTAssertFalse(a.contains("escrowKidC"))
    }
}
