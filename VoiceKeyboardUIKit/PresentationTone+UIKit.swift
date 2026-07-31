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

    /// Status hues are useful for glass tints and meters, but orange/red
    /// text on a translucent surface is not reliably readable in both
    /// appearances or with increased contrast enabled.
    var uiForegroundColor: UIColor {
        switch self {
        case .critical, .warning, .positive:
            .label
        case .muted:
            .secondaryLabel
        }
    }
}
