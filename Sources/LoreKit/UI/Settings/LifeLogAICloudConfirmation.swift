import SwiftUI

extension View {
    /// ライフログAIをクラウドへ送り始める前の確認。設定 > ライフログAI と 設定 > AIプロバイダ の両方が使う。
    /// 確認するまで`pending`は保存されない。
    func lifeLogAICloudConfirmation(_ pending: Binding<LifeLogAISettings?>, env: AppEnvironment) -> some View {
        let name = pending.wrappedValue?.backend.displayName ?? ""
        return alert(
            Text("\(name)へ送信しますか？"),
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } })
        ) {
            Button("送信を許可") {
                guard var next = pending.wrappedValue else { return }
                next.confirmedCloudBackend = next.backend
                env.updateLifeLogAI(next)
                pending.wrappedValue = nil
            }
            Button("キャンセル", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            Text("予定が終わるたびに、その時間の発話とメモの本文を\(name)のAPIへ送ります。1日のまとめでは、その日の発話とメモも送ります。音声は送りません。データはそのサービスの規約に従って扱われます。")
        }
    }
}
