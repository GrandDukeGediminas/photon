import Foundation
import XCTest
@testable import PhotonApp

final class OwnershipTests: XCTestCase {
    var d: TestDefaults!

    override func setUp() { d = TestDefaults() }
    override func tearDown() { d.remove() }

    /// steamcmd's `licenses_for_app 431960` for an account that owns the app (ids and dates replaced).
    static let ownedOutput = """
    Logging in using cached credentials.
    Logging in user 'someone' [U:1:1] to Steam Public...OK
    Waiting for client config...OK
    Waiting for user info...OK
    License packageID 1:
     - State   : Active (flags 0x200) - Purchased : Mon Jan  1 00:00:00 2018 in "XX", Split
     - Apps : 431960, 1790230,  (2 in total)
     - Depots   : 431961, 431966,  (2 in total)
    Unloading Steam API...OK
    """

    func testParse() {
        XCTAssertEqual(OwnershipCheck.owns(Self.ownedOutput), true)
        XCTAssertEqual(OwnershipCheck.owns("Logging in user 'x' [U:1:1] to Steam Public...OK\nWaiting for user info...OK\n"), false)
        XCTAssertEqual(OwnershipCheck.owns(Self.ownedOutput.replacingOccurrences(of: "Active", with: "Expired")), false)
        XCTAssertEqual(OwnershipCheck.owns(Self.ownedOutput.replacingOccurrences(of: "431960, ", with: "4319600, ")), false)
        XCTAssertNil(OwnershipCheck.owns("Logging in user 'x' to Steam Public...FAILED (No Connection)\n"))
    }

    private func check(_ user: String, _ o: OwnershipCheck) -> OwnershipCheck.Status {
        o.username = { user }
        var result: OwnershipCheck.Status?
        o.check { result = $0 }
        let end = Date().addingTimeInterval(10)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return result ?? .unchecked
    }

    func testCheckCachesAndExpires() {
        let o = OwnershipCheck(defaults: d.defaults)
        o.executable = { WorkshopFixtures.fakeSteamcmd }
        o.environment = ["PATH": "/usr/bin:/bin"]
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        o.now = { clock }
        XCTAssertEqual(check("", o), .failed("Enter the Steam account that owns Wallpaper Engine"))
        o.username = { "Someone" }
        XCTAssertFalse(o.mayStart)

        XCTAssertEqual(check("Someone", o), .owned)
        XCTAssertTrue(o.mayStart)
        XCTAssertFalse(o.dueForRecheck)
        o.username = { "someone " }
        XCTAssertTrue(o.mayStart, "the account name is compared without case or spaces")
        o.username = { "other" }
        XCTAssertFalse(o.mayStart, "another account must pass on its own")
        o.username = { "Someone" }

        clock += OwnershipCheck.recheckAfter + 1
        XCTAssertTrue(o.mayStart)
        XCTAssertTrue(o.dueForRecheck)
        clock += OwnershipCheck.offlineGrace
        XCTAssertFalse(o.mayStart, "past the offline grace period Steam must be asked again")

        if case .needsLogin = check("nologin", o) {} else { XCTFail("no saved login") }
        XCTAssertEqual(check("noowner", o), .notOwned)
        XCTAssertEqual(check("expired", o), .notOwned)
        XCTAssertEqual(check("Someone", o), .owned)
        XCTAssertEqual(check("noowner", o), .notOwned)
        o.username = { "Someone" }
        XCTAssertFalse(o.mayStart, "a failed check for the stored account clears it")
    }
}
