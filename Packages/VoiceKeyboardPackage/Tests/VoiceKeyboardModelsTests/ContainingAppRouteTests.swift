import VoiceKeyboardModels
import XCTest

final class ContainingAppRouteTests: XCTestCase {
    func testStartDictationRouteBuildsExpectedURL() {
        XCTAssertNil(ContainingAppRoute.startDictation.url)
    }

    func testRejectsUnauthenticatedStartDictationURL() {
        XCTAssertNil(ContainingAppRoute(url: URL(string: "voicekeyboard://start-dictation")!))
    }

    func testCarriesKeyboardSessionIDThroughStartDictationURL() throws {
        let route = ContainingAppRoute.startDictationForKeyboardSession(sessionID: "keyboard-session-1")

        XCTAssertEqual(
            route.url?.absoluteString,
            "voicekeyboard://start-dictation?sessionID=keyboard-session-1"
        )
        XCTAssertEqual(
            ContainingAppRoute(url: try XCTUnwrap(route.url)),
            route
        )
    }

    func testRejectsUnknownURL() {
        XCTAssertNil(ContainingAppRoute(url: URL(string: "voicekeyboard://settings")!))
        XCTAssertNil(ContainingAppRoute(url: URL(string: "https://start-dictation")!))
    }

    func testRejectsStartDictationURLWithExtraComponents() {
        XCTAssertNil(ContainingAppRoute(url: URL(string: "voicekeyboard://start-dictation/extra")!))
        XCTAssertNil(ContainingAppRoute(url: URL(string: "voicekeyboard://start-dictation?source=test")!))
        XCTAssertNil(ContainingAppRoute(url: URL(string: "voicekeyboard://start-dictation#fragment")!))
    }
}
