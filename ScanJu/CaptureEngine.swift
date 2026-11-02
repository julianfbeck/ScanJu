import ARKit
import AVFoundation
import Combine
import CoreImage
import RoomPlan
import SceneKit
import UIKit

final class CaptureEngine: NSObject, ObservableObject, ARSessionDelegate, RoomCaptureSessionDelegate {
    enum Phase: Equatable { case ready, capturing, processing, finished, failed, cancelled }
    enum Overlay: String, CaseIterable, Identifiable {
        case coverage = "Coverage", wireframe = "Wireframe", camera = "Camera"
        var id: String { rawValue }
    }
    @Published var phase: Phase = .ready
    @Published var guidance = "Move slowly and scan from several angles."
    @Published var points = 0
    @Published var triangles = 0
    @Published var photos = 0
    @Published var walls = 0
    @Published var elapsed = 0.0
    @Published var progress = "Preparing capture"
    @Published var progressFraction = 0.0
    @Published var savedAt: Date?
    @Published var errorMessage: String?
    @Published var result: ScanRecord?
    @Published var tracking = "Initializing"
    @Published var overlay: Overlay = .coverage
    @Published var coverageFocus: CoverageFocus = .searching

    let mode: CaptureMode
    let quality: ScanQuality
    let session = ARSession()
    let sceneView = ARSCNView(frame: .zero)
    private let work = DispatchQueue(label: "ScanJu.capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var roomSession: RoomCaptureSession?
    private var room: CapturedRoom?
    private var pointCloud: PointCloudStore?
    private var checkpoint: CaptureCheckpoint?
    private var lastCheckpoint = Date.distantPast
    private var lastRoomCheckpoint = Date.distantPast
    private var lastStorageCheck = Date.distantPast
    private var memoryObserver: NSObjectProtocol?
    private var chunks: [UUID: MeshChunk] = [:]
    private var samples: [CameraSample] = []
    private var started = Date()
    private var lastFrame = -Double.infinity
    private var lastPhotoTime = -Double.infinity
    private var lastPhotoPose: simd_float4x4?
    private var acceptingFrames = false
    private var finalizing = false
    private var stopRequested = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var notices: [String] = []
    private var liveNodes: [UUID: SCNNode] = [:]
    private let coverageMaterial = CoverageOverlay.material(wireframe: false)
    private let wireframeMaterial = CoverageOverlay.material(wireframe: true)
    private var frameWriteError: String?
    private var depthConfigurationRestored = false
    private let closeUpSurfaces = DepthSurfaceFusion()
    private struct SensorDepth {
        let map: CVPixelBuffer
        let confidence: CVPixelBuffer?
        let source: String
        var calibration: DepthCalibration? = nil
        var filtered: Bool? = nil
    }
    let id = UUID()
    var directory: URL { ScanStore.root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static var supported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) &&
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    static func supported(for mode: CaptureMode) -> Bool {
        if mode != .closeUp { return supported }
        return ARFaceTrackingConfiguration.isSupported && ARFaceTrackingConfiguration.supportsWorldTracking &&
            AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
    }

    init(mode: CaptureMode, quality: ScanQuality) {
        self.mode = mode
        self.quality = quality
        super.init()
        if mode == .closeUp { guidance = "Aim the front camera at a still object, 20–60 cm away. Keep the rear camera clear for tracking." }
        session.delegate = self
        session.delegateQueue = work
        sceneView.session = session
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene = SCNScene()
        sceneView.isPlaying = true
        sceneView.rendersContinuously = true
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.phase == .capturing else { return }
                self.work.async {
                    do {
                        try self.saveCheckpoint(releaseCache: true)
                        self.context.clearCaches()
                    } catch { self.stopForStorageError(error) }
                }
            }
        if mode == .room {
            roomSession = RoomCaptureSession(arSession: session)
            roomSession?.delegate = self
        }
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func start() {
        guard phase == .ready else { return }
        guard Self.supported(for: mode) else {
            fail(mode == .closeUp ? "Close-up capture requires a front TrueDepth camera with world tracking support." : "A LiDAR-equipped iPhone Pro or iPad Pro is required for scanning."); return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.phase == .ready else { return }
                guard granted else {
                    self.fail("Camera access is off. Enable Camera for ScanJu in Settings, then start a new scan."); return
                }
                self.beginWhenActive()
            }
        }
    }

    private func beginWhenActive() {
        guard phase == .ready else { return }
        guard UIApplication.shared.applicationState == .active else {
            if activationObserver == nil {
                activationObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                    object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    if let observer = self.activationObserver { NotificationCenter.default.removeObserver(observer) }
                    self.activationObserver = nil
                    self.beginWhenActive()
                }
            }
            return
        }
        beginCapture()
    }

    private func beginCapture() {
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
            let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard capacity > 600_000_000 else { throw ScanFailure.message("Free at least 600 MB before scanning.") }
            checkpoint = try CaptureCheckpoint(id: id, mode: mode, quality: quality, directory: directory)
            pointCloud = try PointCloudStore(directory: directory.appendingPathComponent("checkpoint/points"), voxelSize: mode.voxelSize(quality))
        } catch { fail(error.localizedDescription); return }
        started = Date()
        stopRequested = false
        work.sync { acceptingFrames = true }
        UIApplication.shared.isIdleTimerDisabled = true
        if mode == .closeUp {
            let configuration = ARFaceTrackingConfiguration()
            configuration.isWorldTrackingEnabled = true
            configuration.isLightEstimationEnabled = false
            if let format = ARFaceTrackingConfiguration.supportedVideoFormats.filter({ $0.framesPerSecond >= 30 }).max(by: {
                $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height
            }) { configuration.videoFormat = format }
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        // Avoid plane flattening: retain measured geometry for ceilings and irregular surfaces.
        configuration.environmentTexturing = .none
        if quality == .detail, let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            configuration.videoFormat = format
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        roomSession?.run(configuration: RoomCaptureSession.Configuration())
        }
        phase = .capturing
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateCaptureStatus()
        }
    }

    // No elapsed-time or thermal cutoff. Keep a small disk reserve so the last
    // checkpoint can be written before a full volume starts rejecting writes.
    func updateCaptureStatus(at now: Date = Date()) {
        guard phase == .capturing else { return }
        elapsed = now.timeIntervalSince(started)
        guard now.timeIntervalSince(lastStorageCheck) >= 5 else { return }
        lastStorageCheck = now
        work.async {
            guard self.acceptingFrames else { return }
            do {
                let capacity = try self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
                if let capacity { try Self.checkRemainingStorage(capacity) }
            } catch { self.stopForStorageError(error) }
        }
    }

    static func checkRemainingStorage(_ bytes: Int64) throws {
        guard bytes > 150_000_000 else {
            throw ScanFailure.message("Device storage is almost full. Free space before starting another scan. Saved capture data is retained.")
        }
    }

    func stop() {
        guard phase == .capturing, !stopRequested else { return }
        stopRequested = true
        phase = .processing
        progress = "Finishing depth capture"
        progressFraction = 0.02
        timer?.invalidate()
        timer = nil
        work.async {
            self.acceptingFrames = false
            do { try self.saveCheckpoint() } catch { self.frameWriteError = error.localizedDescription }
        }
        if let roomSession {
            roomSession.stop(pauseARSession: true)
            // A failed RoomPlan callback must never prevent the detailed mesh being saved.
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, self.phase == .processing else { return }
                self.finish(room: nil, notice: "Room processing timed out. Detailed LiDAR capture was retained.")
            }
        } else {
            session.pause()
            finish(room: nil)
        }
    }

    func cancel() {
        guard phase != .processing else { return }
        phase = .cancelled
        timer?.invalidate()
        timer = nil
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer); activationObserver = nil }
        UIApplication.shared.isIdleTimerDisabled = false
        work.sync { acceptingFrames = false }
        roomSession?.delegate = nil
        roomSession?.stop(pauseARSession: true)
        session.pause()
        work.async { try? FileManager.default.removeItem(at: self.directory) }
    }

    private func fail(_ message: String) {
        errorMessage = message
        phase = .failed
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func finish(room finishedRoom: CapturedRoom?, notice: String? = nil) {
        guard !finalizing else { return }
        finalizing = true
        if let notice { notices.append(notice) }
        let duration = Date().timeIntervalSince(started)
        let notes = notices
        let retainedRoom = finishedRoom ?? room
        work.async { [self] in
            acceptingFrames = false
            let mesh = Array(chunks.values)
            let cloud = pointCloud
            let frames = samples
            let additionalNotes = frameWriteError.map { ["Storage: \($0)"] } ?? []
            chunks.removeAll()
            DispatchQueue.main.async {
                self.liveNodes.values.forEach { $0.removeFromParentNode() }
                self.liveNodes.removeAll()
                self.sceneView.isPlaying = false
                self.sceneView.rendersContinuously = false
                self.sceneView.scene = SCNScene()
            }
            do {
                try cloud?.flush(releaseCache: true)
                try checkpoint?.finish(duration: duration)
                if let finishedRoom {
                    try JSONEncoder().encode(finishedRoom).write(to: directory.appendingPathComponent("checkpoint/Room.json"), options: .atomic)
                }
                context.clearCaches()
                guard (cloud?.count ?? 0) > 0 || !mesh.isEmpty else {
                    throw ScanFailure.message(mode == .closeUp ? "No close-up depth was captured. Face the screen side toward a still object 20–60 cm away, keep the rear camera clear, and move gently in good light." : "No LiDAR geometry was captured. Point at a surface 0.3–5 m away in good light, move the phone slowly, and try again.")
                }
                let record = try ScanProcessor.process(id: id, mode: mode, quality: quality, duration: duration,
                    points: [], pointCloud: cloud, mesh: mesh, frames: frames, room: retainedRoom,
                    notes: notes + additionalNotes, directory: directory) { message, fraction in
                        DispatchQueue.main.async { self.progress = message; self.progressFraction = fraction }
                    }
                pointCloud = nil
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = false
                    self.result = record; self.phase = .finished
                }
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription + " Captured source files remain in ScanJu’s folder in Files.") }
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard acceptingFrames, frame.timestamp - lastFrame >= 0.25 else { return }
        let state: String
        switch frame.camera.trackingState {
        case .normal: state = "Tracking"
        case .notAvailable: state = "Unavailable"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: state = "Move more slowly"
            case .insufficientFeatures: state = "Aim at a detailed, well-lit surface"
            case .initializing: state = "Move gently to initialize"
            case .relocalizing: state = "Return to the scanned area"
            @unknown default: state = "Tracking limited"
            }
        }
        DispatchQueue.main.async {
            self.tracking = state
            if state != "Tracking" { self.coverageFocus = .trackingLimited }
        }
        // Do not fuse samples while the world pose is unreliable.
        guard case .normal = frame.camera.trackingState else { return }
        let depth: SensorDepth
        if mode == .closeUp {
            guard let captured = frame.capturedDepthData, captured.depthDataAccuracy == .absolute,
                  abs(frame.timestamp - frame.capturedDepthDataTimestamp) < 0.075 else { return }
            let metric = captured.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            depth = SensorDepth(map: metric.depthDataMap, confidence: nil, source: "trueDepth",
                calibration: metric.cameraCalibrationData.map(DepthCalibration.init), filtered: metric.isDepthDataFiltered)
        } else if let captured = frame.sceneDepth ?? frame.smoothedSceneDepth {
            depth = SensorDepth(map: captured.depthMap, confidence: captured.confidenceMap,
                source: frame.sceneDepth == nil ? "smoothedSceneDepth" : "sceneDepth")
        } else {
            if !depthConfigurationRestored, Date().timeIntervalSince(started) > 2 {
                depthConfigurationRestored = true
                DispatchQueue.main.async { self.restoreDepthConfiguration() }
            }
            return
        }
        lastFrame = frame.timestamp
        do { try autoreleasepool {
            let image = CIImage(cvPixelBuffer: frame.capturedImage)
            let width = CVPixelBufferGetWidth(depth.map)
            let height = CVPixelBufferGetHeight(depth.map)
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let scale = CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                          y: CGFloat(height) / image.extent.height)
            context.render(image.transformed(by: scale), toBitmap: &rgba, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let k = frame.camera.intrinsics
            let resolution = frame.camera.imageResolution
            var depthK = k
            depthK[0][0] *= Float(width) / Float(resolution.width)
            depthK[1][1] *= Float(height) / Float(resolution.height)
            depthK[2][0] *= Float(width) / Float(resolution.width)
            depthK[2][1] *= Float(height) / Float(resolution.height)
            if let calibration = depth.calibration { depthK = calibration.intrinsics(width: width, height: height) }
            let measuredDepth = centerDepth(depth.map)
            let cameraToWorld = frame.camera.transform
            DispatchQueue.main.async { self.updateCoverageFocus(depth: measuredDepth, cameraToWorld: cameraToWorld) }
            try integrate(depth: depth, colors: rgba, intrinsics: depthK, pose: frame.camera.transform)
            try pointCloud?.trimCache()
            if Date().timeIntervalSince(lastCheckpoint) >= 2 { try saveCheckpoint() }
            let pose = frame.camera.transform
            let displacement = lastPhotoPose.map { simd_distance($0.columns.3, pose.columns.3) } ?? 100
            let angle = lastPhotoPose.map { simd_dot($0.columns.2, pose.columns.2) } ?? -1
            if frame.timestamp - lastPhotoTime >= 0.6,
               displacement > (mode == .closeUp ? 0.015 : 0.12) || angle < (mode == .closeUp ? 0.999 : 0.985) || frame.timestamp - lastPhotoTime > 3 {
                do {
                    try saveFrame(frame, depth: depth, image: image)
                    lastPhotoPose = pose
                    lastPhotoTime = frame.timestamp
                    if mode == .closeUp {
                        let values = packedBuffer(depth.map, bytesPerPixel: 4).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                        let surface = DepthSurfaceBuilder.mesh(depth: values, width: width, height: height, intrinsics: depthK,
                            pose: pose, stride: quality == .detail ? 2 : 3, calibration: depth.calibration)
                        for (identifier, chunk) in closeUpSurfaces.integrate(surface, camera: SIMD3(pose.columns.3.x,pose.columns.3.y,pose.columns.3.z)) {
                            try storeChunk(chunk, identifier: identifier)
                        }
                        let count = chunks.values.reduce(0) { $0 + $1.faces.count }
                        DispatchQueue.main.async { self.triangles = count }
                    }
                } catch {
                    stopForStorageError(error)
                }
            }
            let pointCount = pointCloud?.count ?? 0, frameCount = samples.count
            DispatchQueue.main.async { self.points = pointCount; self.photos = frameCount }
        } } catch { stopForStorageError(error) }
    }

    private func saveCheckpoint(releaseCache: Bool = false) throws {
        try pointCloud?.flush(releaseCache: releaseCache)
        try checkpoint?.saveMetadata(duration: Date().timeIntervalSince(started))
        lastCheckpoint = Date()
        let saved = lastCheckpoint
        DispatchQueue.main.async { self.savedAt = saved }
    }

    private func stopForStorageError(_ error: Error) {
        acceptingFrames = false
        frameWriteError = error.localizedDescription
        DispatchQueue.main.async {
            guard self.phase == .capturing else { return }
            self.notices.append("Capture stopped after a storage error. Previously saved checkpoints were retained.")
            self.stop()
        }
    }

    private func centerDepth(_ buffer: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let x = CVPixelBufferGetWidth(buffer) / 2, y = CVPixelBufferGetHeight(buffer) / 2
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float.self)
        return row[x].isFinite && row[x] > 0 ? row[x] : nil
    }

    private func updateCoverageFocus(depth: Float?, cameraToWorld: simd_float4x4) {
        guard phase == .capturing, !sceneView.bounds.isEmpty else { return }
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let hit = sceneView.hitTest(center, options: [
            .categoryBitMask: CoverageOverlay.category, .ignoreHiddenNodes: false,
            .backFaceCulling: false, .searchMode: SCNHitTestSearchMode.closest.rawValue
        ]).first
        let meshDepth = hit.map { hit -> Float in
            let camera = cameraToWorld.inverse * SIMD4<Float>(hit.worldCoordinates.x, hit.worldCoordinates.y, hit.worldCoordinates.z, 1)
            return -camera.z
        }
        coverageFocus = CoverageFocus.classify(meshDepth: meshDepth, measuredDepth: depth, tracking: tracking == "Tracking",
            range: mode.depthRange, tolerance: mode == .closeUp ? 0.008 : 0.12)
    }

    private func integrate(depth: SensorDepth, colors: [UInt8], intrinsics: simd_float3x3, pose: simd_float4x4) throws {
        let map = depth.map
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        if let confidence = depth.confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence = depth.confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        let confidenceBase = depth.confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceStride = depth.confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let step = mode == .closeUp ? (quality == .detail ? 1 : 2) : quality.stride
        for y in stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            let confidenceRow = confidenceBase?.advanced(by: y * confidenceStride).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: step) {
                let d = row[x]
                guard d.isFinite, mode.depthRange.contains(d), confidenceRow.map({ $0[x] >= 2 }) ?? (mode == .closeUp) else { continue }
                let position = ScanMath.unproject(x: Float(x), y: Float(y), depth: d, intrinsics: intrinsics,
                    cameraToWorld: pose, calibration: depth.calibration, width: width, height: height)
                // CI bitmap rows and camera pixels are both read in their native image order.
                let offset = (y * width + x) * 4
                let color = SIMD3(Float(colors[offset]), Float(colors[offset + 1]), Float(colors[offset + 2]))
                try pointCloud?.integrate(position: position, color: color)
            }
        }
    }

    private func saveFrame(_ frame: ARFrame, depth: SensorDepth, image: CIImage) throws {
        let index = String(format: "%04d", samples.count)
        let jpg = "frames/\(index).jpg", depthName = "frames/\(index).depth", confidenceName = "frames/\(index).confidence"
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.94]) else {
            throw ScanFailure.message("Could not encode camera imagery.")
        }
        try jpeg.write(to: directory.appendingPathComponent(jpg), options: .atomic)
        let depthBytes = packedBuffer(depth.map, bytesPerPixel: 4)
        try depthBytes.write(to: directory.appendingPathComponent(depthName), options: .atomic)
        let confidenceBytes: Data
        if let confidence = depth.confidence { confidenceBytes = packedBuffer(confidence, bytesPerPixel: 1) }
        else if mode == .closeUp {
            confidenceBytes = depthBytes.withUnsafeBytes { bytes in
                Data(bytes.bindMemory(to: Float.self).map { $0.isFinite && mode.depthRange.contains($0) ? UInt8(1) : UInt8(0) })
            }
        } else { throw ScanFailure.message("LiDAR confidence unavailable.") }
        try confidenceBytes.write(to: directory.appendingPathComponent(confidenceName), options: .atomic)
        let k = frame.camera.intrinsics
        samples.append(CameraSample(image: jpg, depth: depthName, confidence: confidenceName,
            timestamp: frame.timestamp, width: CVPixelBufferGetWidth(frame.capturedImage), height: CVPixelBufferGetHeight(frame.capturedImage),
            depthWidth: CVPixelBufferGetWidth(depth.map), depthHeight: CVPixelBufferGetHeight(depth.map),
            intrinsics: (0..<3).flatMap { c in (0..<3).map { r in k[c][r] } },
            cameraToWorld: flatten(frame.camera.transform), tracking: "normal",
            depthSource: depth.source, confidenceSource: mode == .closeUp ? "validDepthMask" : "ARConfidenceLevel",
            depthCalibration: depth.calibration, depthFiltered: depth.filtered))
        // Checkpoint calibration during capture so raw frames remain useful after interruption.
        try JSONEncoder().encode(samples).write(to: directory.appendingPathComponent("cameras.json"), options: .atomic)
    }

    private func packedBuffer(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var result = Data(capacity: width * height * bytesPerPixel)
        for y in 0..<height { result.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * bytesPerPixel) }
        return result
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updateMeshes(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updateMeshes(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard acceptingFrames else { return }
        for anchor in anchors {
            chunks.removeValue(forKey: anchor.identifier)
            do { try checkpoint?.removeMesh(id: anchor.identifier) } catch { stopForStorageError(error) }
            DispatchQueue.main.async { self.liveNodes.removeValue(forKey: anchor.identifier)?.removeFromParentNode() }
        }
    }

    private func updateMeshes(_ anchors: [ARAnchor]) {
        guard acceptingFrames else { return }
        for anchor in anchors.compactMap({ $0 as? ARMeshAnchor }) {
            let source = anchor.geometry.vertices
            let vertices: [SIMD3<Float>] = (0..<source.count).map { index in
                let p = source.buffer.contents().advanced(by: source.offset + source.stride * index).assumingMemoryBound(to: Float.self)
                let v = anchor.transform * SIMD4(p[0], p[1], p[2], 1)
                return SIMD3(v.x, v.y, v.z)
            }
            let element = anchor.geometry.faces
            let faces: [SIMD3<UInt32>] = (0..<element.count).map { face in
                let p = element.buffer.contents().advanced(by: face * element.indexCountPerPrimitive * element.bytesPerIndex)
                if element.bytesPerIndex == 4 {
                    let v = p.assumingMemoryBound(to: UInt32.self)
                    return SIMD3(v[0], v[1], v[2])
                }
                let v = p.assumingMemoryBound(to: UInt16.self)
                return SIMD3(UInt32(v[0]), UInt32(v[1]), UInt32(v[2]))
            }
            let chunk = MeshChunk(vertices: vertices, faces: faces)
            do { try storeChunk(chunk, identifier: anchor.identifier) } catch { stopForStorageError(error); return }
        }
        let count = chunks.values.reduce(0) { $0 + $1.faces.count }
        DispatchQueue.main.async { self.triangles = count }
    }

    private func storeChunk(_ chunk: MeshChunk, identifier: UUID) throws {
            chunks[identifier] = chunk
            try checkpoint?.saveMesh(chunk, id: identifier)
            let geometry = CoverageOverlay.geometry(chunk)
            DispatchQueue.main.async {
                guard self.phase == .capturing else { return }
                let node = self.liveNodes[identifier] ?? SCNNode()
                node.geometry = geometry
                node.categoryBitMask = CoverageOverlay.category
                self.styleOverlay(node)
                if node.parent == nil { self.sceneView.scene.rootNode.addChildNode(node) }
                self.liveNodes[identifier] = node
            }
    }

    func setOverlay(_ overlay: Overlay) {
        self.overlay = overlay
        liveNodes.values.forEach { styleOverlay($0) }
    }

    private func styleOverlay(_ node: SCNNode) {
        node.isHidden = overlay == .camera
        node.renderingOrder = 1000
        node.geometry?.materials = [overlay == .wireframe ? wireframeMaterial : coverageMaterial]
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            guard self.phase == .capturing else { return }
            self.notices.append("Capture ended after an AR session interruption.")
            self.stop()
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            guard self.phase == .capturing else { return }
            self.notices.append("ARKit: \(error.localizedDescription)")
            self.stop()
        }
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async { self.room = room; self.walls = room.walls.count }
        work.async {
            guard self.acceptingFrames, Date().timeIntervalSince(self.lastRoomCheckpoint) >= 2 else { return }
            do {
                try JSONEncoder().encode(room).write(to: self.directory.appendingPathComponent("checkpoint/Room.json"), options: .atomic)
                self.lastRoomCheckpoint = Date()
            } catch { self.stopForStorageError(error) }
        }
    }

    private func restoreDepthConfiguration() {
        guard phase == .capturing,
              let configuration = session.configuration?.copy() as? ARWorldTrackingConfiguration else { return }
        configuration.frameSemantics.formUnion([.sceneDepth, .smoothedSceneDepth])
        configuration.sceneReconstruction = .meshWithClassification
        session.run(configuration, options: [])
    }
    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) { captureSession(session, didUpdate: room) }
    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) { captureSession(session, didUpdate: room) }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String
        switch instruction {
        case .moveCloseToWall: text = "Move closer to the wall."
        case .moveAwayFromWall: text = "Step back to see more of the wall."
        case .slowDown: text = "Slow down for a cleaner scan."
        case .turnOnLight: text = "More light will improve tracking and textures."
        case .lowTexture: text = "Include corners and objects to help tracking."
        case .normal: text = "Sweep from floor to ceiling, then revisit corners."
        @unknown default: text = "Move slowly around the room."
        }
        DispatchQueue.main.async { self.guidance = text }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        DispatchQueue.main.async {
            guard self.phase == .capturing || self.phase == .processing, !self.finalizing else { return }
            // RoomPlan can end independently of the user's detailed AR capture.
            // Retain the latest floor-plan checkpoint and continue mesh/RGB-D in
            // the same coordinate system, without resetting tracking or anchors.
            if !self.stopRequested, self.phase == .capturing {
                self.roomSession?.delegate = nil
                self.roomSession = nil
                self.notices.append("RoomPlan ended before detailed capture. The latest floor plan was retained; mesh, points and camera capture continued.")
                self.restoreDepthConfiguration()
                return
            }
            self.phase = .processing
            self.timer?.invalidate()
            self.timer = nil
            self.session.pause()
            self.work.async { self.acceptingFrames = false }
            self.progress = "Building the room on this iPhone"
            self.progressFraction = 0.05
            if let error {
                self.finish(room: nil, notice: "RoomPlan could not complete a floor plan: \(error.localizedDescription)")
                return
            }
            Task {
                do {
                    let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                    await MainActor.run { self.finish(room: room) }
                } catch {
                    await MainActor.run { self.finish(room: nil, notice: "Floor plan unavailable: \(error.localizedDescription)") }
                }
            }
        }
    }
}
