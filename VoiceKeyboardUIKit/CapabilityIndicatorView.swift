import UIKit
import VoiceKeyboardPresentation

@MainActor
final class CapabilityIndicatorView: UIStackView {
    private enum Metrics {
        static let barCount = ActiveMicrophoneBarCount.maximumVisibleBars
        static let width: CGFloat = 42
        static let height: CGFloat = 8
        static let barSpacing: CGFloat = 3
    }

    private let bars = (0..<Metrics.barCount).map { _ in UIView() }

    init() {
        super.init(frame: .zero)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func render(color: UIColor, activeBars: ActiveMicrophoneBarCount) {
        for (index, bar) in bars.enumerated() {
            let isActive = index < activeBars.value
            bar.backgroundColor = isActive ? color : .tertiaryLabel
            bar.alpha = isActive ? 1 : 0.35
        }
    }

    private func configure() {
        axis = .horizontal
        spacing = Metrics.barSpacing
        distribution = .fillEqually
        isAccessibilityElement = false

        widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true

        for bar in bars {
            bar.layer.cornerRadius = 2
            bar.backgroundColor = .tertiaryLabel
            bar.isAccessibilityElement = false
            addArrangedSubview(bar)
        }
    }
}
