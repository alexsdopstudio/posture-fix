import BiomechanicsCore
import SwiftUI

/// Today's posture in plain words: an hourly timeline, a few insights backed by enough
/// data, and one suggestion. Everything comes from `PostureInsightsEngine`.
public struct InsightsView: View {
    let insights: PostureInsights

    public init(insights: PostureInsights) {
        self.insights = insights
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Oggi")
                    .font(.headline)
                Spacer()
                Text(Self.duration(minutes: insights.trackedMinutes) + " con gli AirPods")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if insights.judgedMinutes < 10 {
                Text("Gli insights compaiono dopo circa 10 minuti con gli AirPods.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HourlyTimeline(hours: insights.hourly)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.text) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: row.icon)
                                .foregroundStyle(row.color)
                                .frame(width: 16)
                            Text(row.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)

                if let tip = insights.tip {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                        Text(Self.text(for: tip))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private struct Row {
        var icon: String
        var color: Color
        var text: String
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let good = insights.goodShare {
            rows.append(Row(icon: "checkmark.circle.fill", color: .green,
                            text: "Postura buona per il \(Int((good * 100).rounded()))% del tempo"))
        }
        if let pitch = insights.habitualPitch {
            var text = Self.habitText(pitch)
            if let previous = insights.previousHabitualPitch {
                let delta = pitch - previous
                if abs(delta) >= 1 {
                    text += delta > 0 ? " · meglio degli ultimi 7 giorni" : " · peggio degli ultimi 7 giorni"
                }
            }
            rows.append(Row(icon: "arrow.up.and.down", color: abs(pitch) < 3 ? .green : .orange, text: text))
        }
        if let lateral = insights.lateralHabit {
            let side = lateral.side == .left ? "sinistra" : "destra"
            rows.append(Row(icon: "arrow.left.and.right", color: .orange,
                            text: "Quando ti inclini, \(Int((lateral.share * 100).rounded()))% delle volte è verso \(side)"))
        }
        if let fatigue = insights.fatigue {
            rows.append(Row(icon: "hourglass", color: .orange,
                            text: "Dopo \(fatigue.thresholdMinutes) min seduto la postura peggiora"))
        }
        if let worst = insights.worstHour {
            rows.append(Row(icon: "clock", color: .orange,
                            text: "Ora più difficile: \(worst.hour):00-\(worst.hour + 1):00"))
        }
        if insights.nudges > 0 {
            var text = "Avvisi: \(insights.nudges)"
            if let latency = insights.meanRecoveryLatencySeconds {
                text += " · ti raddrizzi in \(Int(latency.rounded())) s"
            }
            rows.append(Row(icon: "bell", color: .secondary, text: text))
        }
        return rows
    }

    private static func habitText(_ pitch: Double) -> String {
        let degrees = Int(abs(pitch).rounded())
        if degrees < 2 { return "Testa di solito in asse con il tuo neutro" }
        return pitch < 0
            ? "Testa di solito \(degrees)° più in basso del neutro"
            : "Testa di solito \(degrees)° più in alto del neutro"
    }

    public static func text(for tip: PostureTip) -> String {
        switch tip {
        case let .takeBreaks(minutes):
            return "Alzati ogni \(minutes) minuti, anche solo per un minuto: è il momento in cui inizi a cedere."
        case let .centerWorkspace(side):
            return "Ti inclini spesso a \(side == .left ? "sinistra" : "destra"): controlla che monitor e mouse siano centrati davanti a te."
        case .raiseScreen:
            return "Tieni la testa bassa: alza lo schermo finché il bordo superiore è all'altezza degli occhi."
        case let .microBreak(hour):
            return "Verso le \(hour):00 cedi di più: programma lì una pausa di 2 minuti con qualche chin tuck."
        case .keepGoing:
            return "Ottima giornata: continua così."
        }
    }

    public static func duration(minutes: Double) -> String {
        let total = Int(minutes)
        return total < 60 ? "\(total) min" : "\(total / 60) h \(total % 60) min"
    }
}

/// One bar per hour with data: height = minutes tracked, green = good, red = deviated.
private struct HourlyTimeline: View {
    let hours: [HourlyPosture]

    var body: some View {
        if let first = hours.first?.hour, let last = hours.last?.hour {
            let byHour = Dictionary(uniqueKeysWithValues: hours.map { ($0.hour, $0) })
            VStack(spacing: 3) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(first...last, id: \.self) { hour in
                        bar(byHour[hour])
                    }
                }
                .frame(height: 36)
                HStack {
                    Text("\(first):00")
                    Spacer()
                    if last > first { Text("\(last + 1):00") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bar(_ hour: HourlyPosture?) -> some View {
        let height = 36 * min(1, (hour?.judgedMinutes ?? 0) / 60)
        let deviated = hour?.deviatedShare ?? 0
        return VStack(spacing: 0) {
            Rectangle().fill(.red.opacity(0.85)).frame(height: height * deviated)
            Rectangle().fill(.green.opacity(0.75)).frame(height: height * (1 - deviated))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
