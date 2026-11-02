import SwiftUI

struct LibraryView: View {
    @State private var mode: CaptureMode = .room
    @State private var quality: ScanQuality = .detail
    @State private var scans = ScanStore.load()
    @State private var capturing = false
    @State private var help = false
    @State private var recoveries = ScanRecovery.candidates()
    @State private var recovering: RecoverableScan?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "viewfinder").font(.title2.weight(.bold))
                            Text("ScanJu").font(.title2.weight(.bold)).tracking(-0.8)
                        }
                        Spacer()
                        Button { help = true } label: {
                            Image(systemName: "questionmark").font(.body.weight(.semibold))
                                .frame(width: 42, height: 42).background(.white, in: Circle())
                        }.accessibilityLabel("Scanning guide")
                    }
                    ForEach(recoveries) { capture in
                        Button { recovering = capture } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(capture.title, systemImage: "arrow.clockwise.circle.fill").font(.headline)
                                Text(capture.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Palette.secondary)
                                Text("Your saved data is available. Finish processing without recording again.")
                                    .font(.subheadline)
                                Label("Finish saved scan", systemImage: "arrow.right").font(.subheadline.weight(.semibold))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("recovery.\(capture.id.uuidString)")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Space,\ncaptured.").font(.system(size: 52, weight: .semibold, design: .rounded))
                            .tracking(-2.8).lineSpacing(-4)
                        Text("Turn the world around you into something you can keep.")
                            .font(.body).foregroundStyle(Palette.secondary).frame(maxWidth: 300, alignment: .leading)
                    }
                    ZStack(alignment: .bottomLeading) {
                        RoomIllustration().frame(height: 240)
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("A NEW PERSPECTIVE").font(.system(size: 10, weight: .semibold)).tracking(2)
                                Text("Depth. Color. Every angle.").font(.system(size: 17, weight: .medium))
                            }
                            Spacer()
                            Image(systemName: "cube.transparent").font(.title2)
                        }.foregroundStyle(Palette.mint).padding(22)
                    }.background(Palette.ink, in: RoundedRectangle(cornerRadius: 26)).clipShape(RoundedRectangle(cornerRadius: 26))

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("MAKE A SCAN").font(.system(size: 11, weight: .semibold)).tracking(1.8)
                            Spacer()
                            HStack(spacing: 5) {
                                Circle().fill(CaptureEngine.supported(for: mode) ? Color.green : .orange).frame(width: 6, height: 6)
                                Text((mode == .closeUp ? "TrueDepth" : "LiDAR") + (CaptureEngine.supported(for: mode) ? " ready" : " required")).font(.caption)
                            }.foregroundStyle(Palette.secondary)
                        }
                        HStack(spacing: 12) {
                            ForEach([CaptureMode.room, .surface]) { item in
                                Button { mode = item } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Image(systemName: item.symbol).font(.title2)
                                            Spacer()
                                            Image(systemName: mode == item ? "checkmark.circle.fill" : "circle")
                                        }
                                        Text(item.title).font(.headline)
                                        Text(item == .room ? "All data + floor plan" : "Partial spaces").font(.caption)
                                            .foregroundStyle(mode == item ? Palette.ink.opacity(0.7) : Palette.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                        .background(mode == item ? Palette.mint : .white, in: RoundedRectangle(cornerRadius: 20))
                                }.buttonStyle(.plain).accessibilityIdentifier("mode.\(item.rawValue.lowercased())")
                                    .accessibilityAddTraits(mode == item ? .isSelected : [])
                            }
                        }
                        Button { mode = .closeUp } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "faceid").font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Close-up").font(.headline)
                                    Text("Front TrueDepth · small objects").font(.caption)
                                }
                                Spacer()
                                Image(systemName: mode == .closeUp ? "checkmark.circle.fill" : "circle")
                            }.padding(18).background(mode == .closeUp ? Palette.mint : .white, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("mode.truedepth")
                            .accessibilityAddTraits(mode == .closeUp ? .isSelected : [])
                        Text(mode.summary).font(.footnote).foregroundStyle(Palette.secondary)
                        if mode == .closeUp {
                            Text(quality == .detail ? "1.5 mm fusion grid · native depth sampling" : "3 mm fusion grid · lighter sampling")
                                .font(.caption.weight(.medium))
                            Text("Grid size controls sampling, not measurement accuracy. Keep the object still and the rear camera clear for tracking.")
                                .font(.caption).foregroundStyle(Palette.secondary)
                        }
                        Label("Mesh + textures always on", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(Palette.ink)
                        HStack {
                            Label("Capture quality", systemImage: "slider.horizontal.3").font(.subheadline)
                            Spacer()
                            Picker("Capture quality", selection: $quality) {
                                ForEach(ScanQuality.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.menu).accessibilityIdentifier("capture.quality")
                        }.padding(.vertical, 3)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Your spaces").font(.title2.weight(.semibold)).tracking(-0.6)
                            Spacer()
                            Text("\(scans.count)").font(.caption.monospacedDigit()).padding(.horizontal, 10)
                                .padding(.vertical, 5).background(.white, in: Capsule())
                        }
                        if scans.isEmpty {
                            HStack(spacing: 16) {
                                Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(Palette.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Your first scan starts here.").font(.subheadline.weight(.medium))
                                    Text("Saved on your device. Ready to take anywhere.").font(.caption).foregroundStyle(Palette.secondary)
                                }
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
                        }
                        ForEach(scans) { scan in
                            NavigationLink { ScanDetailView(scan: scan) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: scan.mode.symbol).font(.title2).frame(width: 60, height: 64)
                                        .background(Palette.mint.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(scan.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text("\(scan.pointCount.formatted()) points · \(scan.frameCount) images")
                                            .font(.caption).foregroundStyle(Palette.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").font(.caption)
                                }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(.plain)
                        }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text(deleting ? "Deleting scans…" : "Delete all scans")
                            Spacer()
                            if deleting { ProgressView() }
                        }.font(.subheadline.weight(.medium)).padding(18)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }.accessibilityIdentifier("library.deleteAll").disabled(deleting)
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.gen3")
                        Text("Captured and processed entirely on your iPhone.")
                    }.font(.caption2).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity)
                }.padding(24).padding(.bottom, 12)
            }.disabled(deleting).background(Palette.paper).foregroundStyle(Palette.ink)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom) {
                    Button { capturing = true } label: {
                        HStack {
                            Image(systemName: "viewfinder")
                            Text("Start \(mode.title.lowercased()) scan").fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "arrow.right")
                        }.padding(19).foregroundStyle(Palette.mint).background(Palette.ink, in: Capsule())
                    }.accessibilityIdentifier("capture.start").disabled(!CaptureEngine.supported(for: mode) || deleting)
                        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 12)
                        .background(Palette.paper.opacity(0.97))
                }
                .fullScreenCover(isPresented: $capturing, onDismiss: reload) {
                    CaptureScreen(mode: mode, quality: quality)
                }
                .fullScreenCover(item: $recovering, onDismiss: reload) { RecoveryView(candidate: $0) }
                .sheet(isPresented: $help) { ScanningGuide() }
                .confirmationDialog("Delete all scans?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete all scans", role: .destructive) { deleteAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently removes every scan, camera image, mesh, floor plan, export, and interrupted capture stored in ScanJu on this iPhone.")
                }
                .alert("Could not delete all scans", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                    Button("OK") { deleteError = nil }
                } message: { Text(deleteError ?? "") }
                .onAppear(perform: reload)
        }
    }

    private func reload() { scans = ScanStore.load(); recoveries = ScanRecovery.candidates() }

    private func deleteAll() {
        deleting = true
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try ScanStore.removeAll(); return nil } catch { return error.localizedDescription }
            }.value
            reload(); deleting = false; deleteError = error
        }
    }
}

struct RoomIllustration: View {
    var body: some View {
        Canvas { context, size in
            func point(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
                CGPoint(x: size.width * 0.50 + (x - z) * 58, y: 90 + (x + z) * 22 - y * 55)
            }
            func line(_ a: CGPoint, _ b: CGPoint, opacity: Double, width: CGFloat = 1) {
                var path = Path(); path.move(to: a); path.addLine(to: b)
                context.stroke(path, with: .color(Palette.mint.opacity(opacity)), lineWidth: width)
            }
            for i in 0...12 {
                let a = CGFloat(i) / 4
                line(point(a, 0, 0), point(a, 0, 3), opacity: 0.13)
                line(point(0, 0, a), point(3, 0, a), opacity: 0.13)
                line(point(0, a * 0.68, 0), point(3, a * 0.68, 0), opacity: 0.16)
                line(point(0, a * 0.68, 0), point(0, a * 0.68, 3), opacity: 0.16)
            }
            for x in stride(from: 0.0, through: 3.0, by: 0.15) {
                for y in stride(from: 0.0, through: 2.0, by: 0.15) {
                    let p = point(x, y, 0)
                    context.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 1.8, height: 1.8)), with: .color(Palette.mint.opacity(0.6)))
                }
            }
            for (a,b) in [(point(0,0,0),point(3,0,0)), (point(0,0,0),point(0,0,3)),
                          (point(0,0,0),point(0,2,0)), (point(0,2,0),point(3,2,0)),
                          (point(3,2,0),point(3,0,0)), (point(0,2,0),point(0,2,3)),
                          (point(0,2,3),point(0,0,3))] {
                line(a,b,opacity:0.8,width:1.4)
            }
            for (a,b) in [(point(0.8,0,0),point(0.8,1.5,0)), (point(0.8,1.5,0),point(1.6,1.5,0)),
                          (point(1.6,1.5,0),point(1.6,0,0))] { line(a,b,opacity:1,width:2) }
        }.accessibilityHidden(true)
    }
}

struct ScanningGuide: View {
    var body: some View {
        NavigationStack {
            List {
                Section("A good scan, step by step") {
                    Label("Use a well-lit space. Stay 0.3–5 m from surfaces.", systemImage: "sun.max")
                    Label("Move slowly. Walk around and revisit areas from different angles.", systemImage: "figure.walk")
                    Label("For a room, sweep the floor, all walls, corners, and the ceiling.", systemImage: "square.split.bottomrightquarter")
                    Label("For a ceiling or a small area, choose Surface.", systemImage: "cube.transparent")
                    Label("Finish, inspect the result, then export with AirDrop or Files.", systemImage: "square.and.arrow.up")
                }
                Section("Detail and coverage") {
                    Text("Complete + Detail is the default. It captures mesh, color points, high-resolution camera textures, and available room measurements together. There is no separate texture switch.")
                    Text("Detail uses an 8 mm fusion grid; Balanced uses 15 mm. These control point sampling, not LiDAR accuracy. Glass, mirrors, dark surfaces, and unobserved areas may leave gaps.")
                    Text("A stationary phone can capture the visible surface. A complete room and reliable textures require you to move around it.")
                    Text("Points and camera images have no fixed count limit. Geometry is saved to disk throughout capture, and interrupted scans can be recovered here. Capture has no time limit. It stops when device storage is nearly full, keeping saved data for recovery. iOS may still interrupt the camera. Room dimensions are estimates; check them before building work.")
                }
                Section("Your data") {
                    Text("Scans are processed locally. There is no account, upload, or cloud service. Export includes the mesh, images, native depth and confidence maps, camera calibration, and available floor plans.")
                    Text("You can also find all captures in Files → On My iPhone → ScanJu → Scans.")
                    NavigationLink("Privacy and contact") { PrivacyView() }
                }
                Section("Close-up with TrueDepth") {
                    Text("Choose Close-up for small, stationary objects. Point the front screen and TrueDepth camera toward the object, about 20–60 cm away. Move the phone slowly around it, keeping the rear camera clear for world tracking.")
                    Text("Detail uses a 1.5 mm point fusion grid; Balanced uses 3 mm. These are sampling settings, not guaranteed sensor accuracy. The mesh contains observed depth surfaces; hidden parts and holes are not filled automatically.")
                    Text("Color images and raw TrueDepth maps are saved locally with calibration. TrueDepth exports a valid-depth mask (0 or 1), rather than LiDAR confidence levels. ScanJu does not use Face ID authentication or record face landmarks or expressions.")
                }
            }.navigationTitle("Scanning guide").navigationBarTitleDisplayMode(.inline)
        }.presentationDragIndicator(.visible)
    }
}
