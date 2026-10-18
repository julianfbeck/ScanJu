import Foundation
import simd

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case room = "Room", surface = "Surface", closeUp = "TrueDepth"
    var id: String { rawValue }
    var title: String {
        switch self { case .room: return "Complete"; case .surface: return "Surface"; case .closeUp: return "Close-up" }
    }
    var symbol: String {
        switch self { case .room: return "square.split.bottomrightquarter"; case .surface: return "cube.transparent"; case .closeUp: return "faceid" }
    }
    var summary: String {
        switch self {
        case .room: return "Capture everything: detailed mesh, color points, camera textures, and a floor plan."
        case .surface: return "Detailed mesh, color points, and camera textures for ceilings, furniture, and partial spaces."
        case .closeUp: return "Front TrueDepth capture for small, stationary objects. Keep the screen side facing the object, about 20–60 cm away, and move slowly around it."
        }
    }
    var depthRange: ClosedRange<Float> { self == .closeUp ? 0.15...0.75 : 0.2...5 }
    func voxelSize(_ quality: ScanQuality) -> Float { self == .closeUp ? (quality == .detail ? 0.0015 : 0.003) : quality.voxelSize }
}

enum ScanQuality: String, Codable, CaseIterable, Identifiable {
    case detail = "Detail", balanced = "Balanced"
    var id: String { rawValue }
    var voxelSize: Float { self == .detail ? 0.008 : 0.015 }
    var stride: Int { self == .detail ? 2 : 3 }
}

struct ScanRecord: Codable, Identifiable {
    var id: UUID
    var name: String
    var date: Date
    var mode: CaptureMode
    var duration: Double
    var pointCount: Int
    var triangleCount: Int
    var frameCount: Int
    var wallCount: Int
    var floorArea: Double?
    var files: [String]
    var notes: [String]
    var texturedTriangleCount: Int
    var bytes: Int64

    var directory: URL { ScanStore.root.appendingPathComponent(id.uuidString) }
    var archive: URL { directory.appendingPathComponent("ScanJu.zip") }
}

enum ScanStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
    }

    static func load() -> [ScanRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("scan.json")) else { return nil }
            return try? JSONDecoder().decode(ScanRecord.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    static func save(_ record: ScanRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: record.directory.appendingPathComponent("scan.json"), options: .atomic)
    }

    static func removeAll(in directory: URL = root) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

struct ColoredPoint {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
    var weight: Float
}

struct VoxelKey: Hashable {
    let x: Int32, y: Int32, z: Int32
    init(x: Int32, y: Int32, z: Int32) { self.x = x; self.y = y; self.z = z }
    init(_ position: SIMD3<Float>, size: Float) {
        x = Int32(floor(position.x / size))
        y = Int32(floor(position.y / size))
        z = Int32(floor(position.z / size))
    }
}

struct MeshChunk {
    var vertices: [SIMD3<Float>]
    var faces: [SIMD3<UInt32>]
}

struct CameraSample: Codable {
    let image: String
    let depth: String
    let confidence: String
    let timestamp: Double
    let width: Int
    let height: Int
    let depthWidth: Int
    let depthHeight: Int
    let intrinsics: [Float]
    let cameraToWorld: [Float]
    let tracking: String
    var depthSource: String = "sceneDepth"
    var confidenceSource: String? = nil
    var depthCalibration: DepthCalibration? = nil
    var depthFiltered: Bool? = nil

    var transform: simd_float4x4 { matrix4(cameraToWorld) }
    var calibration: simd_float3x3 {
        if let depthCalibration { return depthCalibration.intrinsics(width: width, height: height) }
        return imageCalibration
    }
    var imageCalibration: simd_float3x3 {
        simd_float3x3(SIMD3(intrinsics[0], intrinsics[1], intrinsics[2]),
                      SIMD3(intrinsics[3], intrinsics[4], intrinsics[5]),
                      SIMD3(intrinsics[6], intrinsics[7], intrinsics[8]))
    }
}

func matrix4(_ values: [Float]) -> simd_float4x4 {
    simd_float4x4(SIMD4(values[0], values[1], values[2], values[3]),
                  SIMD4(values[4], values[5], values[6], values[7]),
                  SIMD4(values[8], values[9], values[10], values[11]),
                  SIMD4(values[12], values[13], values[14], values[15]))
}

func flatten(_ matrix: simd_float4x4) -> [Float] {
    (0..<4).flatMap { c in (0..<4).map { r in matrix[c][r] } }
}

enum ScanMath {
    // ARKit camera looks along -Z; image pixels have their origin at top left.
    static func unproject(x: Float, y: Float, depth: Float, intrinsics: simd_float3x3,
                          cameraToWorld: simd_float4x4, calibration: DepthCalibration? = nil,
                          width: Int = 0, height: Int = 0) -> SIMD3<Float> {
        let pixel = calibration?.rectified(SIMD2(x,y), width: width, height: height) ?? SIMD2(x,y)
        let local = SIMD4((pixel.x - intrinsics[2][0]) * depth / intrinsics[0][0],
                          -(pixel.y - intrinsics[2][1]) * depth / intrinsics[1][1], -depth, 1)
        let world = cameraToWorld * local
        return SIMD3(world.x, world.y, world.z)
    }

    static func project(_ world: SIMD3<Float>, worldToCamera: simd_float4x4,
                        intrinsics: simd_float3x3, width: Int, height: Int, calibration: DepthCalibration? = nil) -> SIMD2<Float>? {
        let p = worldToCamera * SIMD4(world, 1)
        guard p.z < -0.05 else { return nil }
        var pixel = SIMD2(intrinsics[0][0] * p.x / -p.z + intrinsics[2][0], intrinsics[1][1] * -p.y / -p.z + intrinsics[2][1])
        pixel = calibration?.distorted(pixel, width: width, height: height) ?? pixel
        let u = pixel.x / Float(width), v = pixel.y / Float(height)
        guard u >= 0.005, u <= 0.995, v >= 0.005, v <= 0.995 else { return nil }
        return SIMD2(u, 1 - v)
    }

    static func polygonArea(_ points: [SIMD2<Float>]) -> Double {
        guard points.count > 2 else { return 0 }
        return abs(points.indices.reduce(0.0) { value, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return value + Double(a.x * b.y - b.x * a.y)
        }) * 0.5
    }
}
