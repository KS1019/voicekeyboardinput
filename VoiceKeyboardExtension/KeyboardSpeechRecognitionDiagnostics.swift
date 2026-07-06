import Foundation
import os
import VoiceKeyboardModels

struct KeyboardSpeechRecognitionDiagnostics: Sendable {
    private let logger = Logger(
        subsystem: "com.ks1019.voicekeyboardinput.keyboard",
        category: "KeyboardSpeechRecognition"
    )

    func event(_ name: String, metadata: [String: String] = [:]) {
        let details = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.info("\(name, privacy: .public) \(details, privacy: .public)")
    }

    func failure(_ name: String, error: SpeechRecognitionError) {
        logger.error("\(name, privacy: .public) \(String(describing: error), privacy: .public)")
    }
}
