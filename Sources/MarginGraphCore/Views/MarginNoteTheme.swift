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
    public static let topToolbarHeight: CGFloat = 44.0

    // Card Colors (Pastels strictly aligned with MarginNote 3)
    public static let cardDefault = Color(red: 0.96, green: 0.94, blue: 0.86) // #f5efdc
    public static let cardBodyBackground = Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0) // #f5efdc
    public static let cardBorder = Color(red: 0.84, green: 0.81, blue: 0.74)
    public static let cursorBlue = Color(red: 18/255.0, green: 101/255.0, blue: 221/255.0) // #1265dd
    public static let cursorBlueHex = "#1265dd"
    public static let nsCursorColor = NSColor(srgbRed: 18/255.0, green: 101/255.0, blue: 221/255.0, alpha: 1.0)
    public static let cardEditingBoxBackground = Color(white: 0.94).opacity(0.55)

    public static let cardPastels: [(background: Color, border: Color, accent: Color)] = [
        // MarginNote color indices 0...15:
        // 0: Yellow #f3eca0
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 226/255.0, green: 217/255.0, blue: 130/255.0), Color(red: 243/255.0, green: 236/255.0, blue: 160/255.0)),
        // 1: Green #c3ebac
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 169/255.0, green: 214/255.0, blue: 144/255.0), Color(red: 195/255.0, green: 235/255.0, blue: 172/255.0)),
        // 2: Blue #bfdbfe
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 147/255.0, green: 197/255.0, blue: 253/255.0), Color(red: 191/255.0, green: 219/255.0, blue: 254/255.0)),
        // 3: Coral / Light Red #f2bab7
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 230/255.0, green: 165/255.0, blue: 160/255.0), Color(red: 242/255.0, green: 186/255.0, blue: 183/255.0)),
        // 4: Light Purple / Lavender #e0c3e8
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 205/255.0, green: 175/255.0, blue: 215/255.0), Color(red: 224/255.0, green: 195/255.0, blue: 232/255.0)),
        // 5: Orange #f6d2a9
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 235/255.0, green: 190/255.0, blue: 145/255.0), Color(red: 246/255.0, green: 210/255.0, blue: 169/255.0)),
        // 6: Slate Gray #d5d8dc
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 185/255.0, green: 190/255.0, blue: 195/255.0), Color(red: 213/255.0, green: 216/255.0, blue: 220/255.0)),
        // 7: Teal #b5e4de
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 155/255.0, green: 205/255.0, blue: 198/255.0), Color(red: 181/255.0, green: 228/255.0, blue: 222/255.0)),
        // 8: Pink #f5cbe0
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 225/255.0, green: 175/255.0, blue: 200/255.0), Color(red: 245/255.0, green: 203/255.0, blue: 224/255.0)),
        // 9: Lime #dbee9e
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 195/255.0, green: 218/255.0, blue: 135/255.0), Color(red: 219/255.0, green: 238/255.0, blue: 158/255.0)),
        // 10: Aqua #bde6f1
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 160/255.0, green: 205/255.0, blue: 220/255.0), Color(red: 189/255.0, green: 230/255.0, blue: 241/255.0)),
        // 11: Indigo #c9c7f2
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 175/255.0, green: 170/255.0, blue: 225/255.0), Color(red: 201/255.0, green: 199/255.0, blue: 242/255.0)),
        // 12: Peach #f7d2be
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 230/255.0, green: 185/255.0, blue: 160/255.0), Color(red: 247/255.0, green: 210/255.0, blue: 190/255.0)),
        // 13: Mint #b6ecc7
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 155/255.0, green: 215/255.0, blue: 175/255.0), Color(red: 182/255.0, green: 236/255.0, blue: 199/255.0)),
        // 14: Periwinkle #c5d2ea
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 170/255.0, green: 185/255.0, blue: 215/255.0), Color(red: 197/255.0, green: 210/255.0, blue: 234/255.0)),
        // 15: Warm Ochre #ebd8b7
        (Color(red: 245/255.0, green: 239/255.0, blue: 220/255.0), Color(red: 215/255.0, green: 190/255.0, blue: 150/255.0), Color(red: 235/255.0, green: 216/255.0, blue: 183/255.0))
    ]

    public static func cardColors(for colorIndex: Int) -> (background: Color, border: Color, accent: Color) {
        let idx = ((colorIndex % cardPastels.count) + cardPastels.count) % cardPastels.count
        return cardPastels[idx]
    }

    // Badges
    public static let badgePDFRed = Color(red: 0.85, green: 0.25, blue: 0.20)
    public static let badgeGray = Color(red: 0.72, green: 0.70, blue: 0.66)
}

public extension Notification.Name {
    static let marginGraphGoToPage = Notification.Name("marginGraphGoToPage")
    static let marginGraphZoomIn = Notification.Name("marginGraphZoomIn")
    static let marginGraphZoomOut = Notification.Name("marginGraphZoomOut")
    static let marginGraphZoomReset = Notification.Name("marginGraphZoomReset")
}
