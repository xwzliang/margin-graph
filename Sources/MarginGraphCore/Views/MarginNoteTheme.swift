import SwiftUI
import AppKit

public struct MarginNoteTheme {
    // Navigation Sidebar
    public static let sidebarBackground = Color(red: 0.17, green: 0.18, blue: 0.20) // #2B2D32
    public static let sidebarActiveIndicator = Color(red: 0.18, green: 0.65, blue: 0.65) // #2EA6A6
    public static let sidebarActiveBackground = Color(red: 0.22, green: 0.23, blue: 0.26)
    public static let sidebarTextInactive = Color(white: 0.65)
    public static let sidebarTextActive = Color.white

    // Shelf & Canvas
    public static let shelfBackground = Color(red: 0.98, green: 0.965, blue: 0.935) // #FAF6EE
    public static let canvasBackground = Color(red: 0.93, green: 0.91, blue: 0.86) // #EDE8DC
    public static let headerBarBackground = Color(red: 0.98, green: 0.965, blue: 0.935)
    public static let separatorColor = Color(red: 0.88, green: 0.85, blue: 0.79) // #E0D9C9

    // Card Colors (Pastels based on MarginNote 3 palettes)
    public static let cardDefault = Color(red: 0.99, green: 0.985, blue: 0.96)
    public static let cardBorder = Color(red: 0.84, green: 0.81, blue: 0.74)

    public static let cardPastels: [(background: Color, border: Color, accent: Color)] = [
        // 0: Yellow
        (Color(red: 0.99, green: 0.97, blue: 0.85), Color(red: 0.90, green: 0.86, blue: 0.68), Color(red: 0.85, green: 0.75, blue: 0.20)),
        // 1: Red / Coral
        (Color(red: 0.99, green: 0.90, blue: 0.88), Color(red: 0.94, green: 0.76, blue: 0.72), Color(red: 0.88, green: 0.35, blue: 0.30)),
        // 2: Orange
        (Color(red: 1.00, green: 0.94, blue: 0.84), Color(red: 0.95, green: 0.84, blue: 0.68), Color(red: 0.92, green: 0.60, blue: 0.15)),
        // 3: Green
        (Color(red: 0.91, green: 0.97, blue: 0.90), Color(red: 0.78, green: 0.90, blue: 0.75), Color(red: 0.30, green: 0.70, blue: 0.35)),
        // 4: Blue
        (Color(red: 0.90, green: 0.94, blue: 0.99), Color(red: 0.76, green: 0.85, blue: 0.96), Color(red: 0.25, green: 0.55, blue: 0.85)),
        // 5: Purple
        (Color(red: 0.95, green: 0.92, blue: 0.99), Color(red: 0.86, green: 0.78, blue: 0.95), Color(red: 0.60, green: 0.40, blue: 0.85)),
        // 6: Gray / White
        (Color(red: 0.95, green: 0.94, blue: 0.92), Color(red: 0.85, green: 0.83, blue: 0.80), Color(red: 0.55, green: 0.53, blue: 0.50))
    ]

    public static func cardColors(for colorIndex: Int) -> (background: Color, border: Color, accent: Color) {
        let idx = abs(colorIndex) % cardPastels.count
        return cardPastels[idx]
    }

    // Badges
    public static let badgePDFRed = Color(red: 0.85, green: 0.25, blue: 0.20)
    public static let badgeGray = Color(red: 0.72, green: 0.70, blue: 0.66)
}
