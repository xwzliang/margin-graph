import SwiftUI

public struct MarginNoteTooltipModifier: ViewModifier {
    public var text: String
    @State private var isHovered: Bool = false

    public init(text: String) {
        self.text = text
    }

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .overlay(alignment: .bottom) {
                if isHovered && !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.22, green: 0.22, blue: 0.22).opacity(0.95))
                                .shadow(color: Color.black.opacity(0.25), radius: 3, y: 1.5)
                        )
                        .fixedSize()
                        .offset(y: 32)
                        .allowsHitTesting(false)
                        .zIndex(9999)
                }
            }
    }
}

public extension View {
    func marginNoteTooltip(_ text: String) -> some View {
        modifier(MarginNoteTooltipModifier(text: text))
    }
}
