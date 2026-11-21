@testable import VoiceKeyboardInput
import XCTest

@MainActor
final class OnboardingPermissionModelTests: XCTestCase {
    func testRefreshReflectsPermissionChangesWithoutRequestingAccess() {
        var microphone = OnboardingPermissionState.notDetermined
        var requests = 0
        let model = OnboardingPermissionModel(
            microphoneStatus: { microphone },
            speechStatus: { .restricted },
            requestMicrophone: { requests += 1 },
            requestSpeech: { requests += 1 }
        )
        XCTAssertEqual(model.microphone, .notDetermined)
        XCTAssertEqual(model.speech, .restricted)
        microphone = .authorized
        model.refresh()
        XCTAssertEqual(model.microphone, .authorized)
        XCTAssertEqual(requests, 0)
    }

    func testExplicitRequestRefreshesStatusAndDoesNotRepeatDeniedPrompt() async {
        var microphone = OnboardingPermissionState.notDetermined
        var requests = 0
        let model = OnboardingPermissionModel(
            microphoneStatus: { microphone },
            speechStatus: { .authorized },
            requestMicrophone: { requests += 1; microphone = .denied },
            requestSpeech: {}
        )
        await model.allowMicrophone()
        XCTAssertEqual(model.microphone, .denied)
        XCTAssertFalse(model.isRequesting)
        await model.allowMicrophone()
        XCTAssertEqual(requests, 1)
    }

    func testSpeechRequestIsSeparateFromMicrophoneRequest() async {
        var speech = OnboardingPermissionState.notDetermined
        let model = OnboardingPermissionModel(
            microphoneStatus: { .authorized },
            speechStatus: { speech },
            requestMicrophone: { XCTFail("Must not request microphone again") },
            requestSpeech: { speech = .authorized }
        )
        await model.allowSpeech()
        XCTAssertEqual(model.speech, .authorized)
    }
}
