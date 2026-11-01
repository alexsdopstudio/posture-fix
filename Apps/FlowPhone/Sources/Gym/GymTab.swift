import BiomechanicsCore
import FlowUI
import SwiftData
import SwiftUI

struct GymTab: View {
    let gym: GymController
    let deskLoad: DeskLoadSnapshot
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if gym.isSessionActive {
                        activeSession
                    } else {
                        startCard
                        history
                    }
                }
                .padding()
            }
            .navigationTitle("Palestra")
            .task {
                // `-gymDemo YES` launch argument: start a session and run a squat and a curl set
                // (used for simulator screenshots).
                guard UserDefaults.standard.bool(forKey: "gymDemo"), !gym.isSessionActive else { return }
                gym.startSession(deskLoad: deskLoad, context: context)
                gym.simulateSet(.squat)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                gym.simulateSet(.curl)
            }
        }
    }

    // MARK: - Before the workout

    private var startCard: some View {
        let prescription = AdaptivePrescriptionEngine().prescribe(
            desk: deskLoad,
            plan: [PlannedExercise(name: "Esercizi unilaterali", sets: 3, isUnilateral: true)]
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text("Prima dell'allenamento")
                .font(.headline)
            if prescription.adaptations.isEmpty {
                Text("Oggi la postura alla scrivania non richiede correttivi. Buon allenamento!")
                    .foregroundStyle(.secondary)
            } else {
                PrescriptionList(prescription: prescription)
            }
            Text("Metti il telefono in tasca e gli AirPods: la serie parte da sola alla seconda ripetizione.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                gym.startSession(deskLoad: deskLoad, context: context)
            } label: {
                Label("Inizia allenamento", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sessions.isEmpty {
                Text("Allenamenti")
                    .font(.headline)
                ForEach(sessions) { session in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.date.formatted(date: .abbreviated, time: .shortened))
                            Text("\((session.sets ?? []).count) serie")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        FlowScoreBadge(score: session.sessionFlowScore)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    // MARK: - During the workout

    private var activeSession: some View {
        VStack(spacing: 16) {
            if let prescription = gym.prescription, !prescription.adaptations.isEmpty {
                DisclosureGroup("Correttivi di oggi") {
                    PrescriptionList(prescription: prescription).padding(.top, 6)
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            }

            exerciseSetup

            statusCard

            if let set = gym.lastSet {
                SetResultCard(set: set)
            }

            if let sets = gym.currentSession?.sets, sets.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Serie di oggi").font(.headline)
                    ForEach(sets.sorted { $0.id.uuidString < $1.id.uuidString }) { set in
                        HStack {
                            Text(set.exerciseName)
                            Text("· \(set.totalReps) rip.").foregroundStyle(.secondary)
                            Spacer()
                            FlowScoreBadge(score: set.flowScore)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                gym.endSession()
            } label: {
                Text("Termina allenamento").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var exerciseSetup: some View {
        VStack(spacing: 10) {
            Picker("Esercizio", selection: Binding(get: { gym.exerciseName }, set: { gym.exerciseName = $0 })) {
                ForEach(GymController.exercises, id: \.self) { Text($0) }
            }
            Picker("Lato", selection: Binding(get: { gym.side }, set: { gym.side = $0 })) {
                Text("Entrambi").tag(LimbSide.bilateral)
                Text("Sinistro").tag(LimbSide.left)
                Text("Destro").tag(LimbSide.right)
            }
            .pickerStyle(.segmented)
            Stepper(value: Binding(get: { gym.loadKg }, set: { gym.loadKg = $0 }), in: 0...300, step: 2.5) {
                Text("Carico: \(gym.loadKg, specifier: "%.1f") kg")
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: gym.phase == .listening || gym.phase == .recording)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }
            if let message = gym.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if gym.phase == .recording {
                    Button("Fine serie") { gym.stopSetManually() }
                } else {
                    Button("Inizia serie a mano") { gym.startSetManually() }
                        .disabled(gym.phase != .listening)
                }
                Spacer()
                Menu("Simula serie") {
                    Button("Squat (5 ripetizioni)") { gym.simulateSet(.squat) }
                    Button("Curl (10 ripetizioni)") { gym.simulateSet(.curl) }
                }
                .disabled(gym.phase != .listening)
            }
            .font(.callout)
            if !gym.hasPocketPhone {
                Text("Sensori del telefono non disponibili (simulatore): usa \"Simula serie\".")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusText: String {
        switch gym.phase {
        case .idle: return "Pronto"
        case .listening: return "In ascolto: inizia la serie"
        case .recording: return "Serie in corso…"
        case .analyzing: return "Analisi…"
        }
    }

    private var statusIcon: String {
        switch gym.phase {
        case .idle, .listening: return "ear"
        case .recording: return "record.circle"
        case .analyzing: return "waveform"
        }
    }

    private var statusColor: Color {
        switch gym.phase {
        case .recording: return .red
        case .analyzing: return .blue
        default: return .secondary
        }
    }
}

struct PrescriptionList: View {
    let prescription: WorkoutPrescription

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(prescription.preActivation, id: \.name) { drill in
                Label {
                    Text("\(drill.name) · \(drill.sets) serie\(drill.holdSeconds.map { ", fermo \(Int($0)) s" } ?? "")\(drill.side == .bilateral ? "" : (drill.side == .left ? ", lato sinistro" : ", lato destro"))")
                } icon: {
                    Image(systemName: "figure.strengthtraining.functional")
                }
            }
            if !prescription.restInserts.isEmpty {
                Label("Couch Stretch 40 s nei primi \(prescription.restInserts.count) recuperi", systemImage: "figure.flexibility")
            }
            if let weak = prescription.weakSide {
                Label("Unilaterali: inizia dal lato \(weak == .left ? "sinistro" : "destro") e tieni lo stesso ritmo", systemImage: "arrow.left.arrow.right")
            }
        }
        .font(.callout)
    }
}

struct SetResultCard: View {
    let set: ExerciseSet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(set.exerciseName).font(.headline)
                    Text(set.autoDetectedPipeline == .kinematicZUPT ? "Pipeline A · cinematica ZUPT" : "Pipeline B · testa ferma")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(set.flowScore)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(FlowScoreBadge.color(for: set.flowScore))
                    Text("Flow Score").font(.caption2).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metric("Ripetizioni", "\(set.totalReps)")
                metric("Pulite", "\(set.cleanReps)")
                if let mcv = set.meanConcentricVelocity { metric("Vel. media", String(format: "%.2f m/s", mcv)) }
                if let ecc = set.averageEccentricSeconds { metric("Eccentrica", String(format: "%.1f s", ecc)) }
                if let rom = set.thighRomDegrees { metric("ROM femore", String(format: "%.0f°", rom)) }
                if let pitch = set.maxPitchDeviation { metric("Testa avanti", String(format: "%.0f°", pitch)) }
                if let roll = set.maxRollDeviation { metric("Testa lato", String(format: "%.0f°", roll)) }
                if let symmetry = set.bilateralSymmetryRatio { metric("Simmetria", String(format: "%.0f%%", symmetry * 100)) }
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FlowScoreBadge: View {
    let score: Int

    static func color(for score: Int) -> Color {
        score >= 80 ? .green : (score >= 60 ? .orange : .red)
    }

    var body: some View {
        Text("\(score)")
            .font(.callout.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Self.color(for: score))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Self.color(for: score).opacity(0.12), in: Capsule())
    }
}
