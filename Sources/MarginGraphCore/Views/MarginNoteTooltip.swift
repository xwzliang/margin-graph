import SwiftUI
import AppKit

private struct ContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

public struct TooltipContainerWidthEnvKey: EnvironmentKey {
    public static let defaultValue: CGFloat? = nil
}

public extension EnvironmentValues {
    var tooltipContainerWidth: CGFloat? {
        get { self[TooltipContainerWidthEnvKey.self] }
        set { self[TooltipContainerWidthEnvKey.self] = newValue }
    }
}

public struct TooltipContainerModifier: ViewModifier {
    @State private var containerWidth: CGFloat = 0

    public func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    Color.clear.preference(key: ContainerWidthKey.self, value: geo.size.width)
                }
                .allowsHitTesting(false)
            )
            .onPreferenceChange(ContainerWidthKey.self) { w in
                containerWidth = w
            }
            .environment(\.tooltipContainerWidth, containerWidth > 0 ? containerWidth : nil)
            .coordinateSpace(name: "MarginNoteTooltipContainer")
    }
}

public extension View {
    func tooltipContainer() -> some View {
        modifier(TooltipContainerModifier())
    }
}

private struct TooltipButtonFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

public struct MarginNoteTooltipModifier: ViewModifier {
    public var text: String
    @Environment(\.tooltipContainerWidth) var containerWidth
    @State private var isHovered: Bool = false
    @State private var buttonContainerFrame: CGRect = .zero
    @State private var buttonGlobalFrame: CGRect = .zero

    public init(text: String) {
        self.text = text
    }

    private var windowBounds: CGRect {
        if let win = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            return CGRect(origin: .zero, size: win.frame.size)
        }
        return CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    public static func computeOffsets(
        buttonFrame: CGRect,
        text: String,
        boundaryWidth: CGFloat,
        boundaryHeight: CGFloat,
        padding: CGFloat = 8.0
    ) -> (x: CGFloat, y: CGFloat) {
        guard buttonFrame != .zero else { return (0, 32) }
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let w = textSize.width + 18.0
        let h = textSize.height + 9.0

        let idealLeft = buttonFrame.midX - (w / 2.0)
        let idealRight = buttonFrame.midX + (w / 2.0)

        var shiftX: CGFloat = 0
        if idealRight > (boundaryWidth - padding) {
            shiftX = (boundaryWidth - padding) - idealRight
        }
        if idealLeft + shiftX < padding {
            shiftX = padding - idealLeft
        }

        var shiftY: CGFloat = 32.0
        if buttonFrame.maxY + 32.0 + h > boundaryHeight - padding {
            shiftY = -(buttonFrame.height + 8.0)
        }

        return (shiftX, shiftY)
    }

    public static func computeOffsets(
        buttonFrame: CGRect,
        text: String,
        windowSize: CGSize,
        padding: CGFloat = 8.0
    ) -> (x: CGFloat, y: CGFloat) {
        computeOffsets(
            buttonFrame: buttonFrame,
            text: text,
            boundaryWidth: windowSize.width,
            boundaryHeight: windowSize.height,
            padding: padding
        )
    }

    private var offsets: (x: CGFloat, y: CGFloat) {
        let boundWidth = containerWidth ?? windowBounds.width
        let boundHeight = windowBounds.height
        let activeFrame = containerWidth != nil && buttonContainerFrame != .zero ? buttonContainerFrame : buttonGlobalFrame
        return Self.computeOffsets(
            buttonFrame: activeFrame,
            text: text,
            boundaryWidth: boundWidth,
            boundaryHeight: boundHeight
        )
    }

    public func body(content: Content) -> some View {
        let (shiftX, shiftY) = offsets
        return content
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: TooltipButtonFrameKey.self,
                            value: [
                                "container": geo.frame(in: .named("MarginNoteTooltipContainer")),
                                "global": geo.frame(in: .global)
                            ]
                        )
                }
                .allowsHitTesting(false)
            )
            .onPreferenceChange(TooltipButtonFrameKey.self) { frames in
                if let c = frames["container"] { buttonContainerFrame = c }
                if let g = frames["global"] { buttonGlobalFrame = g }
            }
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
                        .offset(x: shiftX, y: shiftY)
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

    /// Surrounds a button or icon with an invisible rectangular hit-testing area,
    /// making it significantly easier to click without changing its visual appearance.
    func enlargedHitTarget(width: CGFloat = 34, height: CGFloat = 32) -> some View {
        modifier(EnlargedHitTargetModifier(width: width, height: height))
    }
}

public struct EnlargedHitTargetModifier: ViewModifier {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat = 34, height: CGFloat = 32) {
        self.width = width
        self.height = height
    }

    public func body(content: Content) -> some View {
        content
            .frame(width: width, height: height)
            .contentShape(Rectangle())
    }
}
