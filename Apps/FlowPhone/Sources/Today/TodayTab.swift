import BiomechanicsCore
import FlowUI
import SwiftUI

struct TodayTab: View {
    let history: PostureHistoryRecorder

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InsightsView(insights: history.insights)
                        .padding()
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                    Label("Questi dati sono solo su questo iPhone. La sincronizzazione con il Mac via iCloud arriverà con l'account sviluppatore.", systemImage: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Oggi")
        }
    }
}
