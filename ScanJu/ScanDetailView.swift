import SwiftUI
import SceneKit
import WebKit

struct ScanDetailView: View {
    let scan: ScanRecord
    @State private var display = "Mesh"
    @State private var showExport = false
    @State private var showFiles = false
    @State private var scene: SCNScene?
    @State private var loading = false
    @State private var previewError: String?
    @State private var shareItem: ExportItem?

    private var hasPlan: Bool { scan.files.contains("FloorPlan.svg") }
    private var coverage: Int { scan.triangleCount > 0 ? Int(Double(scan.texturedTriangleCount) / Double(scan.triangleCount) * 100) : 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A SPACE TO KEEP").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.secondary)
                    Text(scan.mode == .room ? "Your room,\nin a new dimension." : "A different\npoint of view.")
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1.3)
                }
                Picker("Preview", selection: $display) {
                    Text("Mesh").tag("Mesh")
                    Text("Points").tag("Points")
                    if hasPlan { Text("Floor plan").tag("Plan") }
                }.pickerStyle(.segmented).accessibilityIdentifier("preview.mode")
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 24).fill(Palette.ink)
                    if display == "Plan" {
                        PlanPreview(url: scan.directory.appendingPathComponent("FloorPlan.svg"))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    } else if let scene {
                        ModelPreview(scene: scene).clipShape(RoundedRectangle(cornerRadius: 24))
                        Text("Drag to orbit · pinch to zoom").font(.caption2).foregroundStyle(Palette.mint)
                            .padding(10).background(.black.opacity(0.5), in: Capsule()).padding(14)
                    } else if loading {
                        VStack(spacing: 14) { ProgressView().tint(Palette.mint); Text("Loading your scan").font(.caption).foregroundStyle(Palette.mint) }
                            .frame(maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Preview unavailable", systemImage: "cube.transparent", description: Text(previewError ?? "Use an export to inspect this capture."))
                            .foregroundStyle(.white).frame(maxHeight: .infinity)
                    }
                }.frame(height: 340).accessibilityIdentifier("scan.preview")

                HStack(alignment: .top) {
                    stat(scan.pointCount.formatted(.number.notation(.compactName)), "Color points")
                    Spacer()
                    stat("\(scan.frameCount)", "Camera views")
                    Spacer()
                    stat(scan.floorArea.map { String(format: "%.1f m²", $0) } ?? "\(coverage)%", scan.floorArea == nil ? "Textured faces" : "Floor area")
                }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Ready to go places.").font(.title2.weight(.semibold)).tracking(-0.6)
                    Text("Take the 3D model into another app, share the floor plan, or keep every depth frame for later.")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                    Button { showExport = true } label: {
                        HStack { Image(systemName: "square.and.arrow.up"); Text("Export scan").fontWeight(.semibold); Spacer(); Image(systemName: "arrow.up.right") }
                            .padding(19).background(Palette.ink, in: Capsule()).foregroundStyle(Palette.mint)
                    }.accessibilityIdentifier("scan.export")
                    HStack {
                        Label("\(ByteCountFormatter.string(fromByteCount: scan.bytes, countStyle: .file)) of scan data", systemImage: "internaldrive")
                        Spacer()
                        Button("Files") { showFiles = true }.accessibilityIdentifier("scan.files")
                    }.font(.caption).foregroundStyle(Palette.secondary)
                }
                if !scan.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Capture notes", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                        ForEach(Array(scan.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.footnote).foregroundStyle(Palette.secondary)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.mint.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
                }
                Text(scan.date.formatted(date: .long, time: .shortened) + " · " + String(format: "%.0f seconds", scan.duration))
                    .font(.caption2).foregroundStyle(Palette.secondary)
            }.padding(24)
        }.background(Palette.paper).foregroundStyle(Palette.ink)
            .navigationTitle("ScanJu").navigationBarTitleDisplayMode(.inline)
            .task(id: display) { await loadPreview() }
            .sheet(isPresented: $showExport) { exportSheet }
            .sheet(isPresented: $showFiles) { fileSheet }
            .sheet(item: $shareItem) { ActivitySheet(items: [$0.url]) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(Palette.secondary)
        }
    }

    private var exportSheet: some View {
        NavigationStack {
            List {
                if FileManager.default.fileExists(atPath: scan.archive.path) {
                    Section {
                        exportButton("Complete scan", detail: "ZIP · mesh, textures, points, calibration & plans", symbol: "shippingbox", file: "ScanJu.zip")
                    }
                }
                Section("3D") {
                    if scan.files.contains("TexturedMesh.usdz") { exportButton("Textured model", detail: "USDZ · Quick Look and 3D apps", symbol: "cube", file: "TexturedMesh.usdz") }
                    if scan.files.contains("Room.usdz") { exportButton("Room model", detail: "USDZ · parametric walls and objects", symbol: "square.split.bottomrightquarter", file: "Room.usdz") }
                    exportButton("Color point cloud", detail: "PLY · CloudCompare, MeshLab, Blender", symbol: "circle.dotted", file: "PointCloud.ply")
                }
                if hasPlan {
                    Section("Floor plan") {
                        exportButton("Floor plan drawing", detail: "SVG · scalable 2D drawing", symbol: "map", file: "FloorPlan.svg")
                        exportButton("CAD floor plan", detail: "DXF · lines in meters", symbol: "ruler", file: "FloorPlan.dxf")
                    }
                }
                Section {
                    Text("The complete ZIP keeps OBJ materials and JPEG textures together. Unzip before importing Mesh.obj. AirDrop or Save to Files is available in the share sheet.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Export scan").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showExport = false } } }
        }.presentationDragIndicator(.visible)
    }

    private func exportButton(_ title: String, detail: String, symbol: String, file: String) -> some View {
        Button {
            showExport = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { shareItem = ExportItem(url: scan.directory.appendingPathComponent(file)) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "square.and.arrow.up").font(.caption)
            }.padding(.vertical, 8)
        }.accessibilityIdentifier("export.\(file)")
    }

    private var fileSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Files → On My iPhone → ScanJu → Scans → \(scan.id.uuidString)")
                        .font(.footnote).textSelection(.enabled)
                }
                Section("Capture contents") {
                    ForEach(scan.files.filter { !$0.hasPrefix("frames/") }, id: \.self) { file in
                        Text(file).font(.subheadline.monospaced())
                    }
                    Text("\(scan.frameCount) synchronized JPEG + depth + confidence sets in frames/").font(.footnote)
                }
                Section("Geometry") {
                    LabeledContent("Triangles", value: scan.triangleCount.formatted())
                    LabeledContent("Textured triangles", value: scan.texturedTriangleCount.formatted())
                    LabeledContent("Walls", value: scan.wallCount.formatted())
                }
            }.navigationTitle("Scan files").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showFiles = false } } }
        }.presentationDragIndicator(.visible)
    }

    @MainActor private func loadPreview() async {
        guard display != "Plan" else { return }
        scene = nil; loading = true; previewError = nil
        let kind = display
        let directory = scan.directory
        let task = Task.detached(priority: .userInitiated) { () -> Result<SCNScene, Error> in
            Result {
                if kind == "Mesh" {
                    guard scan.triangleCount > 0 else { throw ScanFailure.message("This capture contains points only. Choose Points to inspect it.") }
                    return try ScanProcessor.loadTexturedScene(directory: directory)
                }
                let points = try PointPreviewReader.read(directory.appendingPathComponent("PointCloud.ply"))
                let scene = SCNScene()
                scene.rootNode.addChildNode(SCNNode(geometry: ScanProcessor.pointGeometry(points)))
                return scene
            }
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, display == kind else { return }
        loading = false
        switch result {
        case .success(let value): scene = value
        case .failure(let error): previewError = error.localizedDescription
        }
    }
}

struct ExportItem: Identifiable { let id = UUID(); let url: URL }

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct PlanPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(); view.isOpaque = false
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ModelPreview: UIViewRepresentable {
    let scene: SCNScene
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.07, green: 0.17, blue: 0.15, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.isPlaying = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 30
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        guard view.scene !== scene else { return }
        view.scene = scene
        let (minimum, maximum) = scene.rootNode.boundingBox
        let center = SCNVector3((minimum.x + maximum.x) / 2, (minimum.y + maximum.y) / 2, (minimum.z + maximum.z) / 2)
        let radius = max(0.4, max(maximum.x - minimum.x, max(maximum.y - minimum.y, maximum.z - minimum.z)))
        let camera = SCNNode()
        camera.camera = SCNCamera(); camera.camera?.zNear = 0.01; camera.camera?.zFar = 100
        camera.position = SCNVector3(center.x + radius * 0.85, center.y + radius * 0.7, center.z + radius * 1.3)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        view.defaultCameraController.target = center
    }
}

enum PointPreviewReader {
    static func read(_ url: URL) throws -> [ColoredPoint] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let headerRange = data.range(of: Data("end_header\n".utf8)) else { throw ScanFailure.message("Invalid point-cloud header.") }
        let offset = headerRange.upperBound
        let count = (data.count - offset) / 15
        let step = max(1, count / 150_000)
        return data.withUnsafeBytes { buffer in
            stride(from: 0, to: count, by: step).map { i in
                let index = offset + i * 15
                func f(_ byte: Int) -> Float { Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: byte, as: UInt32.self))) }
                return ColoredPoint(position: SIMD3(f(index), f(index + 4), f(index + 8)),
                    color: SIMD3(Float(data[index + 12]), Float(data[index + 13]), Float(data[index + 14])), weight: 1)
            }
        }
    }
}
