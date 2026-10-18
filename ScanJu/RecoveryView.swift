import SwiftUI

struct ProcessingPanel: View {
    let message: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(Palette.mint)
            Text("Saving your space.").font(.title.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("processing.stage")
            HStack {
                ProgressView(value: fraction).tint(Palette.mint).accessibilityIdentifier("capture.progress")
                Text("\(Int(fraction * 100))%")
                    .font(.subheadline.monospacedDigit()).frame(width: 45, alignment: .trailing)
                    .accessibilityIdentifier("processing.percent")
            }
            Text("Processing on this iPhone. Saved capture data stays available if processing is interrupted.")
                .font(.caption).foregroundStyle(Palette.mint)
        }.padding(30).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 28))
    }
}

final class RecoveryEngine: ObservableObject {
    @Published var message = "Opening saved capture"
    @Published var fraction = 0.0
    @Published var result: ScanRecord?
    @Published var error: String?
    private var running = false
    private let work = DispatchQueue(label: "ScanJu.recovery", qos: .userInitiated, autoreleaseFrequency: .workItem)

    func start(_ candidate: RecoverableScan) {
        guard !running, result == nil else { return }
        running = true; error = nil; fraction = 0
        UIApplication.shared.isIdleTimerDisabled = true
        work.async {
            do {
                let record = try ScanRecovery.recover(candidate) { message, fraction in
                    DispatchQueue.main.async { self.message = message; self.fraction = fraction }
                }
                DispatchQueue.main.async {
                    self.result = record; self.running = false
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription; self.running = false
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }
}

struct RecoveryView: View {
    let candidate: RecoverableScan
    @StateObject private var engine = RecoveryEngine()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let scan = engine.result {
                NavigationStack {
                    ScanDetailView(scan: scan)
                        .toolbar { ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { dismiss() }.accessibilityIdentifier("recovery.done")
                        } }
                }.preferredColorScheme(.light)
            } else {
                ZStack {
                    Palette.ink.ignoresSafeArea()
                    if let error = engine.error {
                        VStack(spacing: 20) {
                            Text("Saved data retained").font(.title2.weight(.semibold))
                            Text(error).font(.subheadline).multilineTextAlignment(.center)
                            Button("Try again") { engine.start(candidate) }.buttonStyle(.borderedProminent)
                            Button("Close") { dismiss() }
                        }.padding(30).foregroundStyle(.white).tint(Palette.mint)
                    } else { ProcessingPanel(message: engine.message, fraction: engine.fraction).padding(24) }
                }.preferredColorScheme(.dark)
            }
        }.interactiveDismissDisabled().task { engine.start(candidate) }
    }
}
