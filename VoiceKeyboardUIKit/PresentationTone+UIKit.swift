import UIKit
import VoiceKeyboardPresentation

extension PresentationTone {
    var uiColor: UIColor {
        switch self {
        case .critical:
            .systemRed
        case .muted:
            .tertiaryLabel
        case .positive:
            .systemGreen
        case .warning:
            .systemOrange
        }
    }
}
