import AppKit
import SwiftUI

/// 複数paneで共有する、dragで幅を変えられる仕切り。
struct ResizableDivider: View {
    @Binding var width: CGFloat
    var minimum: CGFloat
    var maximum: CGFloat

    @State private var widthAtDragStart: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            // 線そのものは 1pt でも、掴める幅は広く取る。
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 9)
                    .contentShape(.rect)
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = widthAtDragStart ?? width
                                widthAtDragStart = start
                                width = min(maximum, max(minimum, start + value.translation.width))
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
            .overlay {
                if isHovering {
                    Rectangle()
                        .fill(KoeTheme.accent.opacity(0.35))
                        .frame(width: 2)
                }
            }
    }
}
