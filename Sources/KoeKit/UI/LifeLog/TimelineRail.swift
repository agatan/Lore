import SwiftUI

/// Timelineの時刻列の右を貫く縦線と、その行の印。
///
/// 行ごとに上下の線を描き、`LazyVStack(spacing: 0)`で積むと一本の線になる。
/// 予定の区間は線を予定の色で太く塗り、予定の外の長い空きは点線にする。
struct TimelineRail: View {
    enum Node: Equatable {
        case none
        /// 発話。本文を主役にするため、印は小さな点だけにする。
        case dot
        /// 予定の始まり。
        case event
        /// memo、音声入力など、利用者が自分で残したもの。
        case symbol(String, Color)
    }

    var node: Node
    /// 印が種類を伝える時だけ、VoiceOverへ同じ意味を渡す。
    var label: String?
    var above: LifeLogTimelineLayout.Segment
    var below: LifeLogTimelineLayout.Segment
    /// 行の上端から印の中心まで。本文1行目の字面の中央に合わせる。
    var nodeCenterY: CGFloat
    var isHighlighted = false
    var compact = false

    static func width(compact: Bool) -> CGFloat { compact ? 26 : 32 }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                segment(above).frame(height: nodeCenterY)
                segment(below).frame(maxHeight: .infinity)
            }
            nodeView
                .frame(width: nodeDiameter, height: nodeDiameter)
                .offset(y: nodeCenterY - nodeDiameter / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement()
        .accessibilityLabel(label.map { Text(LocalizedStringKey($0)) } ?? Text(verbatim: ""))
        .accessibilityHidden(label == nil)
    }

    private var nodeDiameter: CGFloat {
        switch node {
        case .none: 0
        case .dot: compact ? 5 : 6
        case .event: compact ? 10 : 11
        case .symbol: compact ? 17 : 19
        }
    }

    @ViewBuilder
    private func segment(_ segment: LifeLogTimelineLayout.Segment) -> some View {
        switch segment {
        case .none:
            Color.clear.frame(width: 2)
        case .plain:
            Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1.5)
        case .event:
            Rectangle().fill(KoeTheme.accentSecondary.opacity(0.55)).frame(width: 3)
        case .gap:
            DashedLine()
                .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.5, 4.5]))
                .frame(width: 2)
        }
    }

    @ViewBuilder
    private var nodeView: some View {
        switch node {
        case .none:
            EmptyView()
        case .dot:
            Circle().fill(isHighlighted ? AnyShapeStyle(KoeTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.32)))
        case .event:
            Circle()
                .strokeBorder(KoeTheme.accentSecondary, lineWidth: compact ? 2.5 : 3)
                .background(Circle().fill(.background))
        case .symbol(let name, let tint):
            ZStack {
                Circle().fill(.background)
                Circle().fill(tint.opacity(isHighlighted ? 0.32 : 0.16))
                Image(systemName: name)
                    .font(.system(size: compact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

/// Timelineの行の共通の骨格。左から時刻、縦線と印、本文。
struct TimelineRowFrame<Content: View>: View {
    var time: Text?
    var node: TimelineRail.Node
    var nodeLabel: String? = nil
    var above: LifeLogTimelineLayout.Segment
    var below: LifeLogTimelineLayout.Segment
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    /// 本文1行目の字面の中央までの距離。本文の書体の大きさで変わる。
    var firstLineCenter: CGFloat
    var isHighlighted = false
    var compact = false
    @ViewBuilder var content: Content

    static func timeWidth(compact: Bool) -> CGFloat { compact ? 38 : 46 }

    var body: some View {
        let timeWidth = Self.timeWidth(compact: compact)
        let railWidth = TimelineRail.width(compact: compact)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                if let time { time } else { Text(verbatim: " ") }
            }
            .font(KoeTheme.timeFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: timeWidth, alignment: .trailing)
            Color.clear.frame(width: railWidth, height: 1)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .background(alignment: .topLeading) {
            TimelineRail(
                node: node,
                label: nodeLabel,
                above: above,
                below: below,
                nodeCenterY: topPadding + firstLineCenter,
                isHighlighted: isHighlighted,
                compact: compact
            )
            .frame(width: railWidth)
            .padding(.leading, timeWidth)
        }
    }
}
