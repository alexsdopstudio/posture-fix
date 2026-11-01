import BiomechanicsCore
import SwiftData
import SwiftUI

@main
struct FlowPhoneApp: App {
    @State private var model = PhoneAppModel()
    @Environment(\.scenePhase) private var scenePhase

    /// Local SwiftData store for workouts and daily summaries. iCloud sync needs the
    /// Apple Developer Program (CloudKit entitlement), so it is explicitly off for now.
    private let container: ModelContainer = {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            return try ModelContainer(
                for: WorkoutSession.self, ExerciseSet.self, DailyPostureSummary.self,
                configurations: configuration
            )
        } catch {
            fatalError("Flow: cannot open the local workout store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.posture.history.flush() }
        }
    }
}

struct RootView: View {
    let model: PhoneAppModel
    /// `-initialTab today|gym` launch argument (used for simulator screenshots).
    @State private var tab = UserDefaults.standard.string(forKey: "initialTab") ?? "posture"

    var body: some View {
        TabView(selection: $tab) {
            PostureTab(controller: model.posture)
                .tabItem { Label("Postura", systemImage: "figure.mind.and.body") }
                .tag("posture")
            TodayTab(history: model.posture.history)
                .tabItem { Label("Oggi", systemImage: "chart.bar.fill") }
                .tag("today")
            GymTab(gym: model.gym, deskLoad: model.posture.history.todayDeskLoad)
                .tabItem { Label("Palestra", systemImage: "dumbbell.fill") }
                .tag("gym")
        }
        .sheet(isPresented: Binding(
            get: { model.posture.isShowingCalibration },
            set: { if !$0 { model.posture.dismissCalibration() } }
        )) {
            CalibrationSheet(controller: model.posture)
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled(model.posture.calibrationProgress != nil)
        }
    }
}

/// Owns the single AirPods stream and routes it: to the gym while a workout runs,
/// to the posture engine otherwise.
@MainActor
@Observable
final class PhoneAppModel {
    let posture: PhonePostureController
    let gym: GymController

    init() {
        let posture = PhonePostureController()
        let gym = GymController()
        self.posture = posture
        self.gym = gym
        posture.motion.onSample = { [weak posture, weak gym] sample, pose in
            guard let posture, let gym else { return }
            if gym.isSessionActive {
                gym.ingest(sample, isSimulated: posture.motion.isUsingSimulation)
            } else {
                posture.handle(sample: sample, pose: pose)
            }
        }
        posture.motion.start()
    }
}
