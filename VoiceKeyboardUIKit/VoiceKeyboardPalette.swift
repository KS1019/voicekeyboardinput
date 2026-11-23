import UIKit

@MainActor
enum VoiceKeyboardPalette {
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.74, green: 0.69, blue: 0.96, alpha: 1)
            : UIColor(red: 0.36, green: 0.30, blue: 0.62, alpha: 1)
    }

    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
            : UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
    }

    static let surface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.17, alpha: 1)
            : UIColor(white: 1, alpha: 0.9)
    }

    static let onAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    }
}
