import AppKit
import SwiftUI

/// Window背面をぼかすAppKitの素材。Title barを持たない小窓の地に使う。
/// 「透明度を下げる」設定ではAppKitが不透明な色へ自動で置き換える。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
