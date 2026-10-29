import XCTest
@testable import SimpleDisplayCore

final class URLCommandTests: XCTestCase {

    // MARK: - Happy paths

    func testParseOpen() {
        let cmd = try! parse("simpledisplay://open")
        XCTAssertEqual(cmd, .open)
    }

    func testParseCreateMinimal() {
        let cmd = try! parse("simpledisplay://create?width=1920&height=1080")
        guard case .create(let req) = cmd else { return XCTFail() }
        XCTAssertEqual(req.width, 1920)
        XCTAssertEqual(req.height, 1080)
        XCTAssertEqual(req.refreshRate, 60.0)
        XCTAssertFalse(req.hiDPI)
    }

    func testParseCreateFull() {
        let cmd = try! parse("simpledisplay://create?width=2732&height=2048&name=iPad%20Pro&refresh=60&hidpi=true")
        guard case .create(let req) = cmd else { return XCTFail() }
        XCTAssertEqual(req.name, "iPad Pro")
        XCTAssertEqual(req.width, 2732)
        XCTAssertEqual(req.height, 2048)
        XCTAssertTrue(req.hiDPI)
    }

    func testParseRemoveByID() {
        let cmd = try! parse("simpledisplay://remove?id=42")
        XCTAssertEqual(cmd, .remove(.id(42)))
    }

    func testParseRemoveByName() {
        let cmd = try! parse("simpledisplay://remove?name=iPad")
        XCTAssertEqual(cmd, .remove(.name("iPad")))
    }

    func testParseReconfigure() {
        let cmd = try! parse("simpledisplay://reconfigure?id=7&width=1600&height=1200&hidpi=false")
        guard case .reconfigure(let id, let req) = cmd else { return XCTFail() }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(req.width, 1600)
        XCTAssertEqual(req.height, 1200)
    }

    // MARK: - Rejections

    func testRejectsWrongScheme() {
        assertError("http://create?width=100&height=100") { err in
            guard case .wrongScheme = err else { return XCTFail("got \(err)") }
        }
    }

    func testRejectsUnknownAction() {
        assertError("simpledisplay://destroy-everything") { err in
            guard case .unknownHost = err else { return XCTFail("got \(err)") }
        }
    }

    func testRejectsMissingWidth() {
        assertError("simpledisplay://create?height=1080") { err in
            XCTAssertEqual(err, .missingParameter("width"))
        }
    }

    func testRejectsDimensionOutOfRange() {
        assertError("simpledisplay://create?width=10&height=1080") { err in
            guard case .invalidParameter("width", _) = err else { return XCTFail("got \(err)") }
        }
        assertError("simpledisplay://create?width=99999&height=1080") { err in
            guard case .invalidParameter("width", _) = err else { return XCTFail("got \(err)") }
        }
    }

    func testAccepts240HzAndRejectsAbove240() {
        // 240 Hz is a valid virtual-display rate (the old 60 Hz limit was an
        // app-side clamp, not a `CGVirtualDisplay` limitation).
        let cmd = try! parse("simpledisplay://create?width=1920&height=1080&refresh=240")
        guard case .create(let req) = cmd else { return XCTFail("got \(cmd)") }
        XCTAssertEqual(req.refreshRate, 240.0)

        assertError("simpledisplay://create?width=1920&height=1080&refresh=241") { err in
            guard case .invalidParameter("refresh", _) = err else { return XCTFail("got \(err)") }
        }
    }

    func testRejectsNameWithControlChars() {
        // %0A = newline — classic command-injection payload through a shell pipeline.
        assertError("simpledisplay://create?width=1920&height=1080&name=ok%0Abad") { err in
            guard case .invalidParameter("name", _) = err else { return XCTFail("got \(err)") }
        }
    }

    func testRejectsRemoveWithBothIDAndName() {
        assertError("simpledisplay://remove?id=1&name=x") { err in
            guard case .conflictingParameters = err else { return XCTFail("got \(err)") }
        }
    }

    func testRejectsRemoveWithNeitherIDNorName() {
        assertError("simpledisplay://remove") { err in
            XCTAssertEqual(err, .missingParameter("id-or-name"))
        }
    }

    func testRejectsBadBool() {
        assertError("simpledisplay://create?width=800&height=600&hidpi=maybe") { err in
            guard case .invalidParameter("hidpi", _) = err else { return XCTFail("got \(err)") }
        }
    }

    // MARK: - Round-trip

    func testCreateRoundTrip() {
        let original = URLCommand.create(
            VirtualDisplayRequest(name: "Big Screen", width: 3840, height: 2160, refreshRate: 60, hiDPI: true)
        )
        let reparsed = try! parse(original.url.absoluteString)
        XCTAssertEqual(reparsed, original)
    }

    func testReconfigureRoundTrip() {
        let original = URLCommand.reconfigure(
            id: 101,
            request: VirtualDisplayRequest(width: 1024, height: 768, refreshRate: 60, hiDPI: false)
        )
        let reparsed = try! parse(original.url.absoluteString)
        XCTAssertEqual(reparsed, original)
    }

    // MARK: - Enable / disable / mirror

    func testParseEnableByID() throws {
        XCTAssertEqual(try parse("simpledisplay://enable?id=3"),
                       .setEnabled(target: .id(3), enabled: true, headless: false))
    }

    func testParseDisableDefaultsToCountdown() throws {
        XCTAssertEqual(try parse("simpledisplay://disable?name=Dell"),
                       .setEnabled(target: .name("Dell"), enabled: false, headless: false))
    }

    func testParseDisableHeadless() throws {
        XCTAssertEqual(try parse("simpledisplay://disable?id=1&headless=true"),
                       .setEnabled(target: .id(1), enabled: false, headless: true))
    }

    func testRejectsBadHeadlessBool() {
        assertError("simpledisplay://disable?id=1&headless=maybe") { err in
            XCTAssertEqual(err, .invalidParameter("headless", reason: "expected true/false"))
        }
    }

    func testParseMirrorAndUnmirror() throws {
        XCTAssertEqual(try parse("simpledisplay://mirror?id=2"),
                       .setMirrored(target: .id(2), mirrored: true))
        XCTAssertEqual(try parse("simpledisplay://unmirror?name=Twin"),
                       .setMirrored(target: .name("Twin"), mirrored: false))
    }

    func testHeadlessDisableRoundTrip() throws {
        let original = URLCommand.setEnabled(target: .id(7), enabled: false, headless: true)
        XCTAssertEqual(try URLCommandParser.parse(original.url).get(), original)
    }

    func testEnableRoundTripHasNoHeadlessParameter() throws {
        let original = URLCommand.setEnabled(target: .name("Side"), enabled: true, headless: false)
        XCTAssertNil(original.url.query?.range(of: "headless"))
        XCTAssertEqual(try URLCommandParser.parse(original.url).get(), original)
    }

    func testMirrorRoundTrip() throws {
        let original = URLCommand.setMirrored(target: .name("Side"), mirrored: true)
        XCTAssertEqual(try URLCommandParser.parse(original.url).get(), original)
    }

    // MARK: - Mode

    func testParseModeMinimal() throws {
        XCTAssertEqual(try parse("simpledisplay://mode?id=4&width=1600&height=900"),
                       .setMode(target: .id(4), width: 1600, height: 900, hiDPI: nil, refreshRate: nil))
    }

    func testParseModeFull() throws {
        XCTAssertEqual(try parse("simpledisplay://mode?name=Retina&width=800&height=600&hidpi=true&refresh=60"),
                       .setMode(target: .name("Retina"), width: 800, height: 600, hiDPI: true, refreshRate: 60))
    }

    func testModeRequiresDimensions() {
        assertError("simpledisplay://mode?id=4&width=1600") { err in
            XCTAssertEqual(err, .missingParameter("height"))
        }
    }

    func testModeRoundTrip() throws {
        let original = URLCommand.setMode(target: .name("Side"), width: 2560, height: 1440, hiDPI: false, refreshRate: 120)
        XCTAssertEqual(try URLCommandParser.parse(original.url).get(), original)
        let minimal = URLCommand.setMode(target: .id(2), width: 1920, height: 1080, hiDPI: nil, refreshRate: nil)
        XCTAssertNil(minimal.url.query?.range(of: "hidpi"))
        XCTAssertEqual(try URLCommandParser.parse(minimal.url).get(), minimal)
    }

    // MARK: - Helpers

    private func parse(_ string: String) throws -> URLCommand {
        let url = try XCTUnwrap(URL(string: string))
        return try URLCommandParser.parse(url).get()
    }

    private func assertError(
        _ string: String,
        _ check: (URLCommandError) -> Void,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let url = URL(string: string) else {
            return XCTFail("bad test URL: \(string)", file: file, line: line)
        }
        switch URLCommandParser.parse(url) {
        case .success(let cmd):
            XCTFail("expected error, got \(cmd)", file: file, line: line)
        case .failure(let err):
            check(err)
        }
    }
}
