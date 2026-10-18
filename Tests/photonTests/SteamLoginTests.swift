import Combine
import Foundation
import XCTest
@testable import PhotonApp

final class SteamLoginTests: XCTestCase {
    private func waitFor(_ login: SteamLogin, _ timeout: Double = 10, _ cond: (SteamLogin.State) -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond(login.state) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func login() -> SteamLogin {
        let l = SteamLogin()
        l.executable = { WorkshopFixtures.fakeSteamcmd }
        l.environment = ["PATH": "/usr/bin:/bin"]
        return l
    }

    func testPasswordOnly() {
        let l = login()
        l.start(username: "plain")
        waitFor(l) { $0 == .needsPassword }
        XCTAssertEqual(l.state, .needsPassword)
        l.submitPassword("right")
        waitFor(l) { $0 == .signedIn }
        XCTAssertEqual(l.state, .signedIn)
        waitFor(l) { _ in !l.isRunning }
        XCTAssertFalse(l.isRunning)
        XCTAssertEqual(l.state, .signedIn)
    }

    func testWrongPassword() {
        let l = login()
        l.start(username: "plain")
        waitFor(l) { $0 == .needsPassword }
        l.submitPassword("nope")
        waitFor(l) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(l.state, .failed("Wrong username or password"))
    }

    func testEmailCodeRefusedThenAccepted() {
        let l = login()
        l.start(username: "email")
        waitFor(l) { $0 == .needsPassword }
        l.submitPassword("right")
        waitFor(l) { $0 == .needsCode(.email, retry: false) }
        XCTAssertEqual(l.state, .needsCode(.email, retry: false))
        l.submitCode("BAD")
        waitFor(l) { $0 == .needsCode(.email, retry: true) }
        XCTAssertEqual(l.state, .needsCode(.email, retry: true))
        l.submitCode(" GOOD1 ")
        waitFor(l) { $0 == .signedIn }
        XCTAssertEqual(l.state, .signedIn)
    }

    func testAuthenticatorCode() {
        let l = login()
        l.start(username: "app")
        waitFor(l) { $0 == .needsPassword }
        l.submitPassword("right")
        waitFor(l) { $0 == .needsCode(.authenticator, retry: false) }
        XCTAssertEqual(l.state, .needsCode(.authenticator, retry: false))
        l.submitCode("GOOD1")
        waitFor(l) { $0 == .signedIn }
        XCTAssertEqual(l.state, .signedIn)
    }

    /// The Linux steamcmd colours its console even into a pipe: "password: ESC[0m".
    func testColouredLinuxConsole() {
        let l = login()
        l.start(username: "colour")
        waitFor(l) { $0 == .needsPassword }
        XCTAssertEqual(l.state, .needsPassword, "the prompt is recognised behind its colour reset")
        l.submitPassword("right")
        waitFor(l) { $0 == .signedIn }
        XCTAssertEqual(l.state, .signedIn)
        let wrong = login()
        wrong.start(username: "colour")
        waitFor(wrong) { $0 == .needsPassword }
        wrong.submitPassword("nope")
        waitFor(wrong) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(wrong.state, .failed("Wrong username or password"))
    }

    func testEscapeFilter() {
        var f = TerminalEscapeFilter()
        let text = "\u{1b}[1mCached credentials not found.\n\u{1b}[0m\npassword: \u{1b}[0m"
        XCTAssertEqual(String(decoding: f.feed(Array(text.utf8)), as: UTF8.self), "Cached credentials not found.\n\npassword: ")
        // A sequence split across reads, one byte at a time.
        var g = TerminalEscapeFilter()
        let out = Array("a\u{1b}[38;5;12mb\u{1b}(Bc".utf8).flatMap { g.feed([$0]) }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abc")
        var h = TerminalEscapeFilter()
        XCTAssertEqual(String(decoding: h.feed(Array("plain – text".utf8)), as: UTF8.self), "plain – text", "UTF-8 passes through")
    }

    func testApprovedInTheMobileApp() {
        let l = login()
        l.start(username: "phone")
        waitFor(l) { $0 == .needsPassword }
        l.submitPassword("right")
        waitFor(l) { $0 == .working(SteamLogin.approveMessage) }
        XCTAssertEqual(l.state, .working(SteamLogin.approveMessage), "says where to look while steamcmd waits")
        waitFor(l) { $0 == .signedIn }
        XCTAssertEqual(l.state, .signedIn)
    }

    /// The real steamcmd prints nothing while it waits for the Steam Mobile app, then stops with status 5.
    func testSilentWaitForTheMobileApp() {
        let l = login()
        l.start(username: "phonequiet")
        waitFor(l) { $0 == .needsPassword }
        l.submitPassword("right")
        XCTAssertEqual(l.state, .working(SteamLogin.signingInMessage), "the approval is mentioned while it waits")
        waitFor(l) { _ in !l.isRunning }
        XCTAssertEqual(l.state, .failed(SteamLogin.unfinished(status: 5)))
    }

    func testNotApprovedInTime() {
        let l = login()
        l.start(username: "phoneslow")
        waitFor(l) { $0 == .needsPassword }
        l.submitPassword("right")
        waitFor(l) { _ in !l.isRunning }
        XCTAssertEqual(l.state, .failed(SteamLogin.approvalTimedOut))
    }

    func testUnexplainedExitQuotesSteamcmd() {
        XCTAssertEqual(SteamLogin.stopped(status: 5, lastLine: "ERROR (Service Unavailable)"),
                       "steamcmd stopped (status 5): ERROR (Service Unavailable)")
        XCTAssertEqual(SteamLogin.stopped(status: 5, lastLine: nil), "steamcmd stopped (status 5)")
        XCTAssertEqual(SteamLogin.stopped(status: 0, lastLine: nil), "steamcmd stopped without signing in")
    }

    func testCancelAtPasswordPrompt() {
        let l = login()
        l.start(username: "plain")
        waitFor(l) { $0 == .needsPassword }
        l.cancel()
        waitFor(l) { _ in !l.isRunning }
        XCTAssertEqual(l.state, .failed("steamcmd stopped before signing in"))
    }

    func testInstallerUnpacksAndBootstraps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photon-steamcmd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // A stand-in tarball: steamcmd.sh that prints what the real first run ends with.
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let script = src.appendingPathComponent("steamcmd.sh")
        try Data("#!/bin/sh\necho '[----] Verifying installation...'\necho 'Loading Steam API...OK'\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let tarball = root.appendingPathComponent("steamcmd.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tarball.path, "-C", src.path, "steamcmd.sh"]
        try tar.run(); tar.waitUntilExit()

        let i = SteamCmdInstaller()
        i.directory = root.appendingPathComponent("install")
        var asked: URL?
        i.download = { url, done in
            asked = url
            let copy = root.appendingPathComponent("dl.tar.gz")
            try? FileManager.default.copyItem(at: tarball, to: copy)
            done(copy, nil)
        }
        var result: String??
        i.install { result = .some($0) }
        let end = Date().addingTimeInterval(10)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(asked, SteamCmdInstaller.tarball)
        XCTAssertEqual(result, .some(i.directory.appendingPathComponent("steamcmd.sh").path))
        XCTAssertEqual(i.state, .done("steamcmd is ready"))

        let failing = SteamCmdInstaller()
        failing.directory = root.appendingPathComponent("never")
        failing.download = { _, done in done(nil, WorkshopError.http(503)) }
        var r2: String??
        failing.install { r2 = .some($0) }
        let end2 = Date().addingTimeInterval(5)
        while r2 == nil && Date() < end2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(r2, .some(nil))
        if case .failed = failing.state {} else { XCTFail("\(failing.state)") }
    }
}
