import SwiftUI
import UIKit

/// A retro but sober look: white and flat, hairline borders, outline icons, Helvetica Neue,
/// and the steel blue of early Instagram as the one accent. No Liquid Glass.
enum Theme {
    static let ink = Color(hex: 0x262626)
    static let secondary = Color(hex: 0x8E8E8E)
    /// Links, buttons, rings around unseen stories.
    static let accent = Color(hex: 0x3F729B)
    static let like = Color(hex: 0xED4956)
    static let hairline = Color(hex: 0xDBDBDB)
    static let field = Color(hex: 0xEFEFEF)
    static let tray = Color(hex: 0xFAFAFA)

    /// Around an account whose stories you haven't seen.
    static let storyRing = LinearGradient(
        colors: [Color(hex: 0x6A9BC3), accent, Color(hex: 0x2B5273)],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )

    enum Weight {
        case light, regular, medium, bold

        var fontName: String {
            switch self {
            case .light: "HelveticaNeue-Light"
            case .regular: "HelveticaNeue"
            case .medium: "HelveticaNeue-Medium"
            case .bold: "HelveticaNeue-Bold"
            }
        }
    }

    /// Helvetica Neue that still follows the Dynamic Type size.
    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom(weight.fontName, size: size, relativeTo: .body)
    }

    static let wordmark = Font.custom("SnellRoundhand-Bold", size: 28)
    static let icon = Font.system(size: 23, weight: .light)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// "2h", "3d": the short ages stories show.
func shortAge(of date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    // A date from a timestamp that can't be right (not a number, or endlessly far back) mustn't
    // give a count of days too large to be a whole number: none goes past 100,000 days.
    let seconds = interval.isFinite ? min(max(0, interval), 100_000 * 86_400) : 0
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86_400))d"
    }
}

/// Keeps the edge swipe that goes back working, though every screen draws its own bar.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
