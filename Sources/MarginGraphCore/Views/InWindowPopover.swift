import SwiftUI
import AppKit

/// A shape that combines an upward-pointing anchor arrow with a rounded rectangle body.
public struct PopoverBubbleShape: Shape {
    public var arrowX: CGFloat
    public var arrowWidth: CGFloat
    public var arrowHeight: CGFloat
    public var cornerRadius: CGFloat

    public init(
        arrowX: CGFloat,
        arrowWidth: CGFloat = 16,
        arrowHeight: CGFloat = 8,
        cornerRadius: CGFloat = 10
    ) {
        self.arrowX = arrowX
        self.arrowWidth = arrowWidth
        self.arrowHeight = arrowHeight
        self.cornerRadius = cornerRadius
    }

    public var animatableData: CGFloat {
        get { arrowX }
        set { arrowX = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyRect = CGRect(
            x: rect.minX,
            y: rect.minY + arrowHeight,
            width: rect.width,
            height: max(1, rect.height - arrowHeight)
        )
        let minArrowX = bodyRect.minX + cornerRadius + arrowWidth / 2
        let maxArrowX = bodyRect.maxX - cornerRadius - arrowWidth / 2
        let clampedArrowX = max(minArrowX, min(arrowX, maxArrowX))

        // Start at top-left corner
        path.move(to: CGPoint(x: bodyRect.minX + cornerRadius, y: bodyRect.minY))

        // Line to left base of arrow
        path.addLine(to: CGPoint(x: clampedArrowX - arrowWidth / 2, y: bodyRect.minY))
        // Up to arrow tip
        path.addLine(to: CGPoint(x: clampedArrowX, y: rect.minY))
        // Down to right base of arrow
        path.addLine(to: CGPoint(x: clampedArrowX + arrowWidth / 2, y: bodyRect.minY))

        // Line to top-right corner
        path.addLine(to: CGPoint(x: bodyRect.maxX - cornerRadius, y: bodyRect.minY))

        // Top-right corner
        path.addArc(
            center: CGPoint(x: bodyRect.maxX - cornerRadius, y: bodyRect.minY + cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        // Right edge
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - cornerRadius))

        // Bottom-right corner
        path.addArc(
            center: CGPoint(x: bodyRect.maxX - cornerRadius, y: bodyRect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: bodyRect.minX + cornerRadius, y: bodyRect.maxY))

        // Bottom-left corner
        path.addArc(
            center: CGPoint(x: bodyRect.minX + cornerRadius, y: bodyRect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // Left edge
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + cornerRadius))

        // Top-left corner
        path.addArc(
            center: CGPoint(x: bodyRect.minX + cornerRadius, y: bodyRect.minY + cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        path.closeSubpath()
        return path
    }
}

/// A container that hosts popover content completely within the application window boundaries.
public struct InWindowPopoverContainer<Content: View>: View {
    public var anchorFrame: CGRect
    public var containerWidth: CGFloat
    public var popoverWidth: CGFloat
    public var onDismiss: () -> Void
    public var content: () -> Content

    @State private var keyMonitor: Any? = nil

    public init(
        anchorFrame: CGRect,
        containerWidth: CGFloat,
        popoverWidth: CGFloat = 310,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.anchorFrame = anchorFrame
        self.containerWidth = containerWidth
        self.popoverWidth = popoverWidth
        self.onDismiss = onDismiss
        self.content = content
    }

    public var body: some View {
        let margin: CGFloat = 12
        let arrowHeight: CGFloat = 8
        let arrowWidth: CGFloat = 16
        let cornerRadius: CGFloat = 10

        // Clamping width so it never overflows container
        let effectiveWidth = min(popoverWidth, max(180, containerWidth - margin * 2))

        // Center on anchor button, but clamp strictly within [margin, containerWidth - effectiveWidth - margin]
        let idealLeft = anchorFrame.midX - effectiveWidth / 2
        let left = max(margin, min(idealLeft, containerWidth - effectiveWidth - margin))

        // Arrow points to anchorFrame.midX relative to popover card
        let arrowX = anchorFrame.midX - left
        let top = anchorFrame.maxY + 2

        let bubble = PopoverBubbleShape(
            arrowX: arrowX,
            arrowWidth: arrowWidth,
            arrowHeight: arrowHeight,
            cornerRadius: cornerRadius
        )

        ZStack(alignment: .topLeading) {
            // Dismissal backdrop
            Color.black.opacity(0.0001)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismiss()
                }

            // Popover Card
            VStack(spacing: 0) {
                content()
            }
            .frame(width: effectiveWidth)
            .padding(.top, arrowHeight)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(bubble)
            .overlay(
                bubble.stroke(Color(NSColor.separatorColor), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 3)
            .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 8)
            .offset(x: left, y: top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    onDismiss()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
}
