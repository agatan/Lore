import CoreGraphics

enum LifeLogTimelineScrollPolicy {
    static let bottomTolerance: CGFloat = 32

    static func isAtBottom(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        tolerance: CGFloat = bottomTolerance
    ) -> Bool {
        contentHeight <= containerHeight
            || contentOffsetY + containerHeight >= contentHeight - tolerance
    }
}
