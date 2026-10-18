import Foundation
import ImageIO
import RoomPlan
import SceneKit
import simd
import UIKit

enum ScanProcessor {
    struct ProjectionFrame {
        let sample: CameraSample
        let inverse: simd_float4x4
        let depth: Data
        let confidence: Data
    }

    static func process(id: UUID, mode: CaptureMode, quality: ScanQuality, duration: Double,
                        points: [ColoredPoint], pointCloud: PointCloudStore? = nil, mesh: [MeshChunk], frames: [CameraSample],
                        room: CapturedRoom?, notes: [String], directory: URL,
                        progress: (String, Double) -> Void) throws -> ScanRecord {
        var warnings = notes
        let pointCount = pointCloud?.count ?? points.count
        var lastMessage = "", lastFraction = -1.0, lastPersisted = Date.distantPast
        func report(_ message: String, _ fraction: Double) {
            let value = max(lastFraction, min(1, max(0, fraction)))
            guard message != lastMessage || value - lastFraction >= 0.005 || value == 1 else { return }
            progress(message, value)
            if message != lastMessage || Date().timeIntervalSince(lastPersisted) > 1 {
                try? message.write(to: directory.appendingPathComponent("Processing.txt"), atomically: true, encoding: .utf8)
                lastPersisted = Date()
            }
            lastMessage = message; lastFraction = value
        }
        report("Writing the color point cloud", 0.08)
        if let pointCloud {
            try pointCloud.writePLY(to: directory.appendingPathComponent("PointCloud.ply")) { report("Writing the color point cloud", 0.08 + $0 * 0.10) }
        } else {
            try writePLY(points, to: directory.appendingPathComponent("PointCloud.ply")) { report("Writing the color point cloud", 0.08 + $0 * 0.10) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(frames).write(to: directory.appendingPathComponent("cameras.json"), options: .atomic)
        report("Projecting camera textures onto the mesh", 0.18)
        let texturedCount = try writeOBJ(mesh: mesh, frames: frames, directory: directory) { report("Projecting camera textures onto the mesh", 0.18 + $0 * 0.46) }
        let triangleCount = mesh.reduce(0) { $0 + $1.faces.count }
        if triangleCount == 0 { warnings.append("No reconstructed triangles were available. The color point cloud and RGB-D frames are preserved.") }
        if texturedCount < triangleCount {
            warnings.append("\(triangleCount - texturedCount) triangles have no unobstructed camera view and use a neutral material. Revisit surfaces from several angles to improve texture coverage.")
        }

        var area: Double?
        if let room, !room.walls.isEmpty {
            report("Drawing the measured floor plan", 0.65)
            try encoder.encode(room).write(to: directory.appendingPathComponent("Room.json"), options: .atomic)
            area = try FloorPlanExporter.write(room: room, directory: directory)
            do { try room.export(to: directory.appendingPathComponent("Room.usdz"), exportOptions: .parametric) }
            catch { warnings.append("Room USDZ export failed: \(error.localizedDescription). Room JSON and plan exports are retained.") }
            if room.walls.count < 3 || area == nil {
                warnings.append("The floor plan is partial. Scan the floor and every wall to capture a complete room.")
            }
        } else if mode == .room {
            warnings.append("A complete room was not detected. Surface geometry and camera data remain available.")
        }

        if triangleCount > 0 {
            report("Creating the portable 3D model", 0.74)
            do {
                let output = directory.appendingPathComponent("TexturedMesh.usdz")
                // Stream the original JPEGs into USDZ without decoding all camera
                // textures into memory or relying on SceneKit's texture conversion.
                try ZipArchive.create(at: output, root: directory,
                    files: ["Mesh.usda"] + frames.map(\.image), alignment: 64) { report("Creating the portable 3D model", 0.74 + $0 * 0.13) }
            } catch { warnings.append("Textured USDZ unavailable: \(error.localizedDescription). The OBJ is retained.") }
        }

        if mode == .closeUp {
            warnings.append("Front TrueDepth capture of observed surface patches. Unseen areas remain open; keep the object stationary while moving the phone. Fusion grid size is not guaranteed measurement accuracy.")
        }
        try readme(mode: mode, quality: quality, notes: warnings).write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        report("Saving the scan library entry", 0.88)
        let files = try relativeFiles(directory)
        let bytes = try files.reduce(Int64(0)) { value, name in
            value + Int64(try directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        var record = ScanRecord(id: id,
            name: mode.title + " · " + Date().formatted(date: .abbreviated, time: .shortened),
            date: Date(), mode: mode, duration: duration, pointCount: pointCount, triangleCount: triangleCount,
            frameCount: frames.count, wallCount: room?.walls.count ?? 0, floorArea: area,
            files: files + ["scan.json"], notes: warnings, texturedTriangleCount: texturedCount, bytes: bytes)
        try ScanStore.save(record)
        report("Packaging the export", 0.9)
        do {
            try ZipArchive.create(at: record.archive, root: directory, files: record.files) { report("Packaging the export", 0.9 + $0 * 0.1) }
        } catch {
            record.notes.append("ZIP packaging failed: \(error.localizedDescription). Export individual files or use the ScanJu folder in Files.")
            try ScanStore.save(record)
        }
        report("Scan ready", 1)
        return record
    }

    static func geometry(_ mesh: MeshChunk) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let indices = mesh.faces.flatMap { [$0.x, $0.y, $0.z] }
        return SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    static func loadTexturedScene(directory: URL) throws -> SCNScene {
        try MeshPreviewLoader.load(directory: directory)
    }

    static func pointGeometry(_ points: [ColoredPoint]) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: points.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) })
        var colors = Data(capacity: points.count * 16)
        for point in points {
            colors.appendFloat(point.color.x / 255); colors.appendFloat(point.color.y / 255)
            colors.appendFloat(point.color.z / 255); colors.appendFloat(1)
        }
        let colorSource = SCNGeometrySource(data: colors, semantic: .color, vectorCount: points.count,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let element = SCNGeometryElement(indices: (0..<points.count).map(UInt32.init), primitiveType: .point)
        element.pointSize = 2.5; element.minimumPointScreenSpaceRadius = 1; element.maximumPointScreenSpaceRadius = 5
        let geometry = SCNGeometry(sources: [source, colorSource], elements: [element])
        let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        return geometry
    }

    static func writePLY(_ points: [ColoredPoint], to url: URL, progress: (Double) -> Void = { _ in }) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let header = "ply\nformat binary_little_endian 1.0\ncomment ScanJu meters Y-up\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        try handle.write(contentsOf: Data(header.utf8))
        var buffer = Data(capacity: 65536)
        for (index, point) in points.enumerated() {
            buffer.appendFloat(point.position.x); buffer.appendFloat(point.position.y); buffer.appendFloat(point.position.z)
            buffer.append(UInt8(clamping: Int(point.color.x.rounded())))
            buffer.append(UInt8(clamping: Int(point.color.y.rounded())))
            buffer.append(UInt8(clamping: Int(point.color.z.rounded())))
            if buffer.count > 65500 {
                try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                progress(Double(index + 1) / Double(max(1, points.count)))
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        progress(1)
    }

    static func writeOBJ(mesh: [MeshChunk], frames: [CameraSample], directory: URL,
                         progress: (Double) -> Void = { _ in }) throws -> Int {
        let projections = try frames.map { frame in
            ProjectionFrame(sample: frame, inverse: frame.transform.inverse,
                depth: try Data(contentsOf: directory.appendingPathComponent(frame.depth), options: .mappedIfSafe),
                confidence: try Data(contentsOf: directory.appendingPathComponent(frame.confidence), options: .mappedIfSafe))
        }
        var materials = "newmtl unobserved\nKd 0.48 0.56 0.55\nKa 0.2 0.2 0.2\nd 1\nillum 1\n"
        for (index, frame) in frames.enumerated() {
            materials += "\nnewmtl camera_\(index)\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd \(frame.image)\n"
        }
        try materials.write(to: directory.appendingPathComponent("Mesh.mtl"), atomically: true, encoding: .utf8)
        let url = directory.appendingPathComponent("Mesh.obj")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("# ScanJu textured mesh. Meters, right-handed, Y up.\nmtllib Mesh.mtl\n".utf8))
        let usd = try USDMeshWriter(url: directory.appendingPathComponent("Mesh.usda"), frames: frames)
        defer { usd.close() }
        var vertexOffset = 1, textureOffset = 1, texturedCount = 0
        let totalFaces = max(1, mesh.reduce(0) { $0 + $1.faces.count })
        var completedFaces = 0
        for (chunkIndex, chunk) in mesh.enumerated() {
            try autoreleasepool {
            guard !chunk.vertices.isEmpty else { return }
            var text = "o patch_\(chunkIndex)\n"
            for v in chunk.vertices { text += "v \(v.x) \(v.y) \(v.z)\n" }
            try handle.write(contentsOf: Data(text.utf8))
            let center = chunk.vertices.reduce(SIMD3<Float>.zero, +) / Float(chunk.vertices.count)
            // Bound work per face; choose nearby keyframes that can actually see this patch.
            let candidates = projections.indices.filter { index in
                // A patch can cross the image edge even when its center is outside.
                // Keep views of any vertex, then perform precise per-face checks.
                let projection = projections[index]
                return chunk.vertices.contains {
                    ScanMath.project($0, worldToCamera: projection.inverse,
                        intrinsics: projection.sample.calibration, width: projection.sample.width,
                        height: projection.sample.height, calibration: projection.sample.depthCalibration) != nil
                }
            }.sorted {
                simd_distance_squared(center, SIMD3(projections[$0].sample.transform.columns.3.x,
                    projections[$0].sample.transform.columns.3.y, projections[$0].sample.transform.columns.3.z)) <
                simd_distance_squared(center, SIMD3(projections[$1].sample.transform.columns.3.x,
                    projections[$1].sample.transform.columns.3.y, projections[$1].sample.transform.columns.3.z))
            }.prefix(12)
            var groups: [Int: [(SIMD3<UInt32>, [SIMD2<Float>])]] = [:]
            for face in chunk.faces {
                let vertices = [chunk.vertices[Int(face.x)], chunk.vertices[Int(face.y)], chunk.vertices[Int(face.z)]]
                let centroid = (vertices[0] + vertices[1] + vertices[2]) / 3
                let cross = simd_cross(vertices[1] - vertices[0], vertices[2] - vertices[0])
                guard simd_length_squared(cross) > 1e-12 else { continue }
                let normal = simd_normalize(cross)
                var bestIndex = -1, bestScore: Float = 0
                var bestUV: [SIMD2<Float>] = []
                for index in candidates {
                    let frame = projections[index], sample = frame.sample
                    let camera = sample.transform.columns.3
                    let delta = SIMD3(camera.x, camera.y, camera.z) - centroid
                    let distance = simd_length(delta)
                    guard distance > 0.05 else { continue }
                    let incidence = abs(simd_dot(normal, delta / distance))
                    let score = incidence / max(distance * distance, 0.2)
                    guard incidence > 0.15, score > bestScore else { continue }
                    let uvs = vertices.compactMap {
                        ScanMath.project($0, worldToCamera: frame.inverse, intrinsics: sample.calibration,
                                         width: sample.width, height: sample.height, calibration: sample.depthCalibration)
                    }
                    guard uvs.count == 3,
                          visible(centroid, frame: frame), vertices.allSatisfy({ visible($0, frame: frame) }) else { continue }
                    bestIndex = index; bestScore = score; bestUV = uvs
                }
                if bestIndex >= 0 { texturedCount += 1 }
                groups[bestIndex, default: []].append((face, bestUV))
            }
            for index in groups.keys.sorted() {
                try usd.append(chunk: chunk, faces: groups[index] ?? [], name: "patch_\(chunkIndex)_m\(index + 1)", material: index)
                // Give every material its own object. SceneKit's OBJ importer can
                // collapse material changes within a single object on iOS.
                text = "o patch_\(chunkIndex)_\(index < 0 ? "unobserved" : "camera_\(index)")\nusemtl \(index < 0 ? "unobserved" : "camera_\(index)")\n"
                for (face, uv) in groups[index] ?? [] {
                    if index >= 0 {
                        for v in uv { text += "vt \(v.x) \(v.y)\n" }
                        text += "f \(Int(face.x) + vertexOffset)/\(textureOffset) \(Int(face.y) + vertexOffset)/\(textureOffset + 1) \(Int(face.z) + vertexOffset)/\(textureOffset + 2)\n"
                        textureOffset += 3
                    } else {
                        text += "f \(Int(face.x) + vertexOffset) \(Int(face.y) + vertexOffset) \(Int(face.z) + vertexOffset)\n"
                    }
                    if text.utf8.count > 65536 { try handle.write(contentsOf: Data(text.utf8)); text = "" }
                }
                if !text.isEmpty { try handle.write(contentsOf: Data(text.utf8)) }
            }
            vertexOffset += chunk.vertices.count
            completedFaces += chunk.faces.count
            progress(Double(completedFaces) / Double(totalFaces))
            }
        }
        try usd.finish()
        return texturedCount
    }

    private static func visible(_ point: SIMD3<Float>, frame: ProjectionFrame) -> Bool {
        let s = frame.sample
        guard let uv = ScanMath.project(point, worldToCamera: frame.inverse, intrinsics: s.calibration,
                                       width: s.width, height: s.height, calibration: s.depthCalibration) else { return false }
        let x = min(s.depthWidth - 1, max(0, Int(uv.x * Float(s.depthWidth))))
        let y = min(s.depthHeight - 1, max(0, Int((1 - uv.y) * Float(s.depthHeight))))
        let i = y * s.depthWidth + x
        guard i < frame.confidence.count, frame.confidence[i] >= 1, (i + 1) * 4 <= frame.depth.count else { return false }
        let measured = frame.depth.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
        let p = frame.inverse * SIMD4(point, 1)
        // Reject both foreground occluders and surfaces inconsistent with this depth frame.
        let tolerance: Float = s.depthSource == "trueDepth" ? max(0.0035, measured * 0.012) : max(0.08, measured * 0.035)
        return measured.isFinite && measured > 0 && abs(measured + p.z) < tolerance
    }

    static func relativeFiles(_ directory: URL) throws -> [String] {
        // Ask Foundation for relative paths directly. URL enumerators can normalize
        // /var to /private/var on devices, so trimming a root string is unsafe.
        try FileManager.default.subpathsOfDirectory(atPath: directory.path).filter { name in
            guard !name.hasPrefix("checkpoint/"), name != "CaptureDraft.json", !name.hasSuffix(".partial"), name != "ScanJu.zip" else { return false }
            return try directory.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted()
    }

    private static func readme(mode: CaptureMode, quality: ScanQuality, notes: [String]) -> String {
        """
        ScanJu — on-device \(mode == .closeUp ? "front TrueDepth close-up" : "LiDAR") capture

        PointCloud.ply: binary little-endian XYZ float32 (meters) + RGB uint8.
        Mesh.obj + Mesh.mtl + frames/*.jpg: textured triangle mesh. Keep these together.
        Mesh.usda: OpenUSD mesh with calibrated UVs and Preview Surface materials.
        TexturedMesh.usdz: portable mesh with original-resolution JPEG textures.
        Room.usdz: parametric RoomPlan model, when a room was detected.
        FloorPlan.svg: measured 2D wall/opening drawing; labels in meters.
        FloorPlan.dxf: CAD lines with $INSUNITS=6 (meters); X=world X, Y=-world Z.
        Room.json: full Apple RoomPlan semantic result, if available.
        cameras.json: calibration and poses for each synchronized RGB-D keyframe.

        Coordinate conventions
        All 3D output uses ARKit world coordinates: right-handed, Y up, meters.
        cameraToWorld and intrinsics are column-major matrices (4x4 and 3x3).
        Camera looks down -Z; +X right, +Y up. Image pixels: top-left origin.
        JPEGs retain native camera orientation; intrinsics refer to these exact images.
        Depth files: tightly packed little-endian float32 meters, depthWidth x depthHeight.
        Confidence files: tightly packed uint8. ARConfidenceLevel: 0 low, 1 medium, 2 high.
        TrueDepth has no LiDAR confidence levels: validDepthMask is 0 invalid, 1 valid.
        Each camera entry identifies confidenceSource and depthSource.
        Intrinsics must be scaled to depth resolution when unprojecting depth pixels.
        ARKit sceneDepth is preferred; smoothedSceneDepth is used if RoomPlan exposes
        only smoothed depth. Each camera entry records the exact depthSource.
        Rear points fuse high-confidence depths, 0.2–5 m. TrueDepth accepts metric depth
        between 0.15 and 0.75 m; aim for 20–60 cm. TrueDepth calibration includes optical
        intrinsics, reference dimensions, distortion center and forward/inverse radial LUTs.
        Rectify raw depth pixels before unprojection; distort rectilinear UVs for raw imagery.
        depthFiltered records AVDepthData filtering when available. Face anchors are not saved.
        Fusion grid: \(mode.voxelSize(quality)) m. This is a sampling setting, not a claim of sensor accuracy.
        Close-up meshes triangulate observed depth neighborhoods and reject depth edges.
        Best observed patches replace repeated views in spatial tiles. This is not a
        watertight reconstruction; seams and holes may remain. Keep the subject still.
        Textures use calibrated camera projection with depth-occlusion checks.
        Neutral triangles have no reliable camera observation. Texture coverage is in scan.json.

        Points are fused into disk-backed voxel tiles without a fixed point-count cap.
        Recording stops after four minutes; storage, thermal and export format limits still apply.
        LiDAR does not recover unseen surfaces. Reflective/transparent objects and poor light
        can leave holes. A static ceiling capture is a partial surface, not a complete room.
        Floor plans are estimates. Verify dimensions before design or construction work.

        Import Mesh.obj into Blender with Y Forward / Z Up adjusted as needed for ARKit Y up,
        or use USDZ in Quick Look. Use CloudCompare or MeshLab for the PLY cloud.
        Files are available in Files > On My iPhone > ScanJu > Scans.
        Processing is local; ScanJu makes no network requests.

        Capture notes
        \(notes.isEmpty ? "No processing warnings." : notes.joined(separator: "\n"))
        """
    }
}

enum FloorPlanExporter {
    struct Segment {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var kind: String
        var length: Float
    }

    static func write(room: CapturedRoom, directory: URL) throws -> Double? {
        let surfaces = room.walls + room.doors + room.windows + room.openings
        let segments: [Segment] = surfaces.map { surface in
            let half = surface.dimensions.x / 2
            let a = surface.transform * SIMD4<Float>(-half, 0, 0, 1)
            let b = surface.transform * SIMD4<Float>(half, 0, 0, 1)
            return Segment(a: SIMD2(a.x, a.z), b: SIMD2(b.x, b.z), kind: String(describing: surface.category), length: surface.dimensions.x)
        }
        guard !segments.isEmpty else { return nil }
        let positions = segments.flatMap { [$0.a, $0.b] }
        let minX = positions.map(\.x).min()!, maxX = positions.map(\.x).max()!
        let minY = positions.map(\.y).min()!, maxY = positions.map(\.y).max()!
        let scale: Float = 100, margin: Float = 90
        let width = max(480, (maxX - minX) * scale + margin * 2)
        let height = max(400, (maxY - minY) * scale + margin * 2)
        func p(_ point: SIMD2<Float>) -> SIMD2<Float> { SIMD2((point.x - minX) * scale + margin, (point.y - minY) * scale + margin) }
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\"><rect width=\"100%\" height=\"100%\" fill=\"#f5f6f0\"/><g font-family=\"Helvetica,Arial,sans-serif\">"
        svg += "<text x=\"24\" y=\"30\" font-size=\"16\" fill=\"#153b34\">ScanJu · measured plan · meters</text>"
        var dxf = "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n6\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        for segment in segments {
            let a = p(segment.a), b = p(segment.b)
            let isWall = segment.kind.lowercased().contains("wall")
            let color = isWall ? "#153b34" : "#24a987"
            svg += "<line x1=\"\(a.x)\" y1=\"\(a.y)\" x2=\"\(b.x)\" y2=\"\(b.y)\" stroke=\"\(color)\" stroke-width=\"\(isWall ? 6 : 9)\" stroke-linecap=\"round\"/>"
            if isWall {
                svg += "<text x=\"\((a.x + b.x)/2 + 8)\" y=\"\((a.y + b.y)/2 - 10)\" font-size=\"13\" fill=\"#153b34\">\(String(format: "%.2f m", segment.length))</text>"
            }
            dxf += "0\nLINE\n8\n\(isWall ? "WALLS" : "OPENINGS")\n10\n\(segment.a.x)\n20\n\(-segment.a.y)\n30\n0\n11\n\(segment.b.x)\n21\n\(-segment.b.y)\n31\n0\n"
        }
        svg += "<text x=\"24\" y=\"\(height - 20)\" font-size=\"11\" fill=\"#60716b\">Green: doors, windows, openings. Verify measurements. Unscanned areas may be missing.</text></g></svg>"
        dxf += "0\nENDSEC\n0\nEOF\n"
        try svg.write(to: directory.appendingPathComponent("FloorPlan.svg"), atomically: true, encoding: .utf8)
        try dxf.write(to: directory.appendingPathComponent("FloorPlan.dxf"), atomically: true, encoding: .utf8)
        let areas = room.floors.map { floor -> Double in
            let corners = floor.polygonCorners.map { corner -> SIMD2<Float> in
                let v = floor.transform * SIMD4(corner, 1)
                return SIMD2(v.x, v.z)
            }
            return ScanMath.polygonArea(corners)
        }
        let total = areas.reduce(0, +)
        return total > 0.05 ? total : nil
    }
}
