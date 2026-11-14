import SwiftUI

/// 入力レベルの履歴を左から右へ流す波形。
///
/// Canvas で描くのはバー数が多くても再描画コストを一定に保つため。
/// 声の大小がそのまま形に出ることを最優先にし、飾りの減衰カーブは持たせない。
struct WaveformView: View {
    var levels: [Float]
    var isActive: Bool

    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 3
    /// 無音でも芯が見えるように残す最小の高さ。
    private let minimumHeight: CGFloat = 2.5

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let count = max(levels.count, 1)
            let pitch = (size.width + gap) / CGFloat(count)
            let width = max(1.5, min(barWidth, pitch - gap))
            let centerY = size.height / 2

            var path = Path()
            for (index, level) in levels.enumerated() {
                // 小さい声でも動きが分かるよう緩く持ち上げ、上限で頭打ちにする。
                let amplitude = min(1, pow(CGFloat(max(0, level)), 0.62) * 1.15)
                let height = max(minimumHeight, amplitude * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * pitch,
                    y: centerY - height / 2,
                    width: width,
                    height: height
                )
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: width / 2, height: width / 2))
            }

            context.fill(
                path,
                with: .color(LoreTheme.accent)
            )
        }
        .opacity(isActive ? 1 : 0.4)
        // レベルは毎チャンク(数十 ms)更新されるので、アニメーションは短く。
        .animation(.linear(duration: 0.06), value: levels)
    }
}
