import SwiftUI
import SceneKit
import ARKit

struct CaptureScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine: CaptureEngine
    @State private var confirmDiscard = false

    init(mode: CaptureMode, quality: ScanQuality) {
        _engine = StateObject(wrappedValue: CaptureEngine(mode: mode, quality: quality))
    }

    var body: some View {
        Group {
            if let scan = engine.result {
                NavigationStack {
                    ScanDetailView(scan: scan)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() }.accessibilityIdentifier("capture.done") } }
                }.preferredColorScheme(.light)
            } else {
                ZStack {
                    LiveCamera(engine: engine).ignoresSafeArea()
                    LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.3),
                        .init(color: .clear, location: 0.65), .init(color: .black.opacity(0.9), location: 1)],
                        startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                    if engine.phase == .capturing, engine.overlay != .camera {
                        focusIndicator.ignoresSafeArea().allowsHitTesting(false)
                    }
                    VStack(spacing: 14) {
                        HStack {
                            Button { confirmDiscard = true } label: {
                                Image(systemName: "xmark").font(.body.weight(.semibold))
                                    .frame(width: 44, height: 44).background(.black.opacity(0.4), in: Circle())
                            }.accessibilityLabel("Discard capture").disabled(engine.phase == .processing)
                            Spacer()
                            Text(engine.mode.title.uppercased() + " CAPTURE").font(.system(size: 11, weight: .semibold)).tracking(2)
                            Spacer()
                            Text(timeLabel).font(.caption.monospacedDigit()).frame(width: 44)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(engine.tracking == "Tracking" ? Palette.mint : .orange).frame(width: 7, height: 7)
                            Text(engine.tracking).font(.caption.weight(.medium))
                        }.padding(.horizontal, 14).padding(.vertical, 9).background(.black.opacity(0.45), in: Capsule())
                        if engine.phase == .capturing {
                            if engine.mode == .closeUp {
                                Label("FRONT TRUEDEPTH · 20–60 CM", systemImage: "faceid")
                                    .font(.caption2.weight(.semibold)).padding(10)
                                    .background(.black.opacity(0.65), in: Capsule())
                                    .accessibilityIdentifier("capture.trueDepth")
                            }
                            HStack(spacing: 4) {
                                ForEach(CaptureEngine.Overlay.allCases) { overlay in
                                    Button { engine.setOverlay(overlay) } label: {
                                        Text(overlay.rawValue).font(.caption.weight(.semibold))
                                            .padding(.horizontal, 15).padding(.vertical, 10)
                                            .foregroundStyle(engine.overlay == overlay ? Palette.ink : .white)
                                            .background(engine.overlay == overlay ? Palette.mint : .clear, in: Capsule())
                                    }.accessibilityIdentifier("overlay.\(overlay.rawValue.lowercased())")
                                        .accessibilityAddTraits(engine.overlay == overlay ? .isSelected : [])
                                }
                            }.padding(4).background(.black.opacity(0.5), in: Capsule())
                            if engine.overlay == .coverage {
                                coverageLegend
                            } else if engine.overlay == .wireframe {
                                Text("Mesh lines mark captured surfaces")
                                    .font(.caption.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(.black.opacity(0.7), in: Capsule())
                            } else {
                                Text("Camera view · geometry and textures still recording")
                                    .font(.caption2).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.black.opacity(0.7), in: Capsule())
                            }
                        }
                        Spacer()
                        if engine.phase == .capturing {
                            VStack(spacing: 16) {
                                Text(engine.mode != .closeUp && engine.overlay == .coverage ? "Move until the camera gaps fill with mesh." : engine.guidance)
                                    .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                                HStack {
                                    metric(engine.points.formatted(.number.notation(.compactName)), "POINTS")
                                    Spacer()
                                    metric(engine.triangles.formatted(.number.notation(.compactName)), "TRIANGLES")
                                    Spacer()
                                    metric("\(engine.photos)", "IMAGES")
                                }.padding(.horizontal, 20).padding(.vertical, 14).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
                                    .accessibilityIdentifier("capture.metrics")
                                if engine.mode == .room { Text("\(engine.walls) walls detected").font(.caption).foregroundStyle(Palette.mint) }
                                if engine.savedAt != nil {
                                    Label("Capture autosaved", systemImage: "checkmark.shield")
                                        .font(.caption2).foregroundStyle(Palette.mint).accessibilityIdentifier("capture.autosaved")
                                }
                                Button { engine.stop() } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "stop.fill").font(.caption)
                                        Text("Finish & process").fontWeight(.semibold)
                                    }.frame(maxWidth: .infinity).padding(20).foregroundStyle(Palette.ink)
                                        .background(Palette.mint, in: Capsule())
                                }.accessibilityIdentifier("capture.finish")
                            }
                        } else if engine.phase == .processing {
                            Spacer()
                            ProcessingPanel(message: engine.progress, fraction: engine.progressFraction)
                                .accessibilityIdentifier("capture.processing")
                            Spacer()
                        } else if engine.phase == .failed {
                            VStack(spacing: 20) {
                                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                                Text("Capture needs attention").font(.title2.weight(.semibold))
                                Text(engine.errorMessage ?? "Capture failed.").font(.subheadline).multilineTextAlignment(.center)
                                Button("Close") { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.mint).foregroundStyle(Palette.ink)
                            }.padding(26).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 24))
                            Spacer()
                        }
                    }.padding(24).foregroundStyle(.white)
                }.preferredColorScheme(.dark)
            }
        }
        .interactiveDismissDisabled()
        .task { engine.start() }
        .onChange(of: scenePhase) { _, phase in if phase == .background, engine.phase == .capturing { engine.stop() } }
        .confirmationDialog("Discard this capture?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive) { engine.cancel(); dismiss() }
            Button("Keep scanning", role: .cancel) {}
        }
    }

    private var coverageLegend: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).fill(Palette.mint).frame(width: 30, height: 30)
                    .overlay { Image(systemName: "triangle").font(.system(size: 21, weight: .medium)).foregroundStyle(Palette.ink) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAPTURED").font(.system(size: 10, weight: .bold)).tracking(0.7)
                    Text("Solid mesh").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 30)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3]))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOT CAPTURED").font(.system(size: 10, weight: .bold)).tracking(0.7)
                    Text("Camera gaps").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine).accessibilityIdentifier("capture.coverageLegend")
    }

    private var focusIndicator: some View {
        GeometryReader { proxy in
            let captured = engine.coverageFocus == .captured
            let color: Color = captured ? Palette.mint : .white
            ZStack {
                Circle().strokeBorder(color, lineWidth: 2).frame(width: 32, height: 32)
                Image(systemName: captured ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(color)
            }
            .padding(5).background(.black.opacity(0.55), in: Circle())
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            Text(engine.coverageFocus.title).font(.caption.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 13).padding(.vertical, 8).background(.black.opacity(0.75), in: Capsule())
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2 + 47)
                .accessibilityIdentifier("capture.focusStatus")
        }
    }

    private var timeLabel: String { String(format: "%02d:%02d", Int(engine.elapsed) / 60, Int(engine.elapsed) % 60) }
    private func metric(_ value: String, _ name: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
            Text(name).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct LiveCamera: UIViewRepresentable {
    let engine: CaptureEngine
    func makeUIView(context: Context) -> ARSCNView { engine.sceneView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
