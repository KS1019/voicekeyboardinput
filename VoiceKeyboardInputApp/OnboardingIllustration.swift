import SwiftUI

struct OnboardingIllustration: View {
    let step: OnboardingView.Step
    let accent: Color
    let animates: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animates)) { context in
            let phase = animates ? context.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                Ellipse()
                    .fill(accent.opacity(0.08))
                    .frame(width: 230, height: 195)
                    .blur(radius: 22)
                switch step {
                case .microphone:
                    VStack(spacing: 24) {
                        waveform(phase: phase, height: 100)
                        Text("YOUR VOICE, IN MOTION")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(2)
                            .foregroundStyle(accent.opacity(0.75))
                        Text("Illustration · not recording")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                case .speech:
                    VStack(alignment: .leading, spacing: 20) {
                        waveform(phase: phase, height: 42)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "text.alignleft")
                                .foregroundStyle(accent)
                            Text("Let’s meet for\ncoffee tomorrow.")
                                .font(.system(size: 23, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("EXAMPLE TRANSCRIPT")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.5)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(surface, in: RoundedRectangle(cornerRadius: 25))
                    .shadow(color: accent.opacity(0.07), radius: 20, y: 8)
                    .rotationEffect(.degrees(-3))
                    .padding(.horizontal, 8)
                case .keyboard:
                    keyboardPreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private var surface: Color {
        Color(uiColor: VoiceKeyboardPalette.surface)
    }

    private func waveform(phase: Double, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<27, id: \.self) { index in
                let envelope = sin(Double(index + 1) / 28 * .pi)
                let movement = 0.35 + 0.65 * abs(sin(Double(index) * 0.82 + phase * 1.6))
                Capsule()
                    .fill(accent.opacity(0.4 + 0.6 * envelope))
                    .frame(width: 4, height: max(5, height * envelope * movement))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private var keyboardPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("A little less typing.")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                Rectangle().fill(accent).frame(width: 2, height: 21)
                Spacer(minLength: 0)
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(accent)
                Text("Ready when you are")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                previewKey("globe")
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                    Text("Speak")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                .foregroundStyle(accent)
                previewKey("delete.left")
                previewKey("return")
            }
            Text("KEYBOARD PREVIEW")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(surface, in: RoundedRectangle(cornerRadius: 25))
        .shadow(color: accent.opacity(0.07), radius: 20, y: 8)
        .rotationEffect(.degrees(-2))
    }

    private func previewKey(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .frame(width: 39, height: 46)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }
}
