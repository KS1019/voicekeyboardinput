import UIKit
import VoiceKeyboardPresentation

@MainActor
final class VoiceActivityMeterView: UIStackView {
    private enum Metrics {
        static let barCount = VoiceActivityMeterBarCount.standardVisibleBars.value
        static let width: CGFloat = 78
        static let height: CGFloat = 28
        static let minimumBarHeight: CGFloat = 4
        static let barSpacing: CGFloat = 3
    }

    private let bars = (0..<Metrics.barCount).map { _ in UIView() }
    private var barHeightConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func render(snapshot: VoiceActivityMeterSnapshot, color: UIColor) {
        for ((bar, heightConstraint), barLevel) in zip(zip(bars, barHeightConstraints), snapshot.barLevels) {
            let isActive = barLevel > 0
            bar.backgroundColor = isActive ? color : .tertiaryLabel
            bar.alpha = isActive ? 1 : 0.35
            heightConstraint.constant = max(
                Metrics.minimumBarHeight,
                Metrics.height * barLevel
            )
        }
    }

    var barCount: VoiceActivityMeterBarCount {
        .standardVisibleBars
    }

    private func configure() {
        axis = .horizontal
        spacing = Metrics.barSpacing
        alignment = .center
        distribution = .fillEqually
        isAccessibilityElement = false

        widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true

        for bar in bars {
            bar.layer.cornerRadius = 2
            bar.backgroundColor = .tertiaryLabel
            bar.isAccessibilityElement = false
            addArrangedSubview(bar)
            barHeightConstraints.append(
                bar.heightAnchor.constraint(equalToConstant: Metrics.minimumBarHeight)
            )
        }
        NSLayoutConstraint.activate(barHeightConstraints)
    }
}
