import Foundation
import simd

enum DepthSurfaceBuilder {
    /// Triangulate neighboring measured samples, never across a depth step.
    static func mesh(depth: [Float], width: Int, height: Int, intrinsics: simd_float3x3,
                     pose: simd_float4x4, stride step: Int = 2, calibration: DepthCalibration? = nil) -> MeshChunk {
        guard width > step, height > step, step > 0, depth.count == width * height else { return MeshChunk(vertices: [], faces: []) }
        let columns = (width - 1) / step + 1, rows = (height - 1) / step + 1
        var indices = [Int32](repeating: -1, count: columns * rows)
        var vertices: [SIMD3<Float>] = [], distances: [Float] = [], faces: [SIMD3<UInt32>] = []
        for y in 0..<rows { for x in 0..<columns {
            let d = depth[(y * step) * width + x * step]
            guard d.isFinite, CaptureMode.closeUp.depthRange.contains(d) else { continue }
            indices[y * columns + x] = Int32(vertices.count)
            vertices.append(ScanMath.unproject(x: Float(x * step), y: Float(y * step), depth: d, intrinsics: intrinsics,
                cameraToWorld: pose, calibration: calibration, width: width, height: height))
            distances.append(d)
        } }
        func triangle(_ a: Int32, _ b: Int32, _ c: Int32) {
            guard a >= 0, b >= 0, c >= 0 else { return }
            let minimum = min(distances[Int(a)], min(distances[Int(b)], distances[Int(c)]))
            let maximum = max(distances[Int(a)], max(distances[Int(b)], distances[Int(c)]))
            guard maximum - minimum <= max(0.004, minimum * 0.025) else { return }
            faces.append(SIMD3(UInt32(a),UInt32(b),UInt32(c)))
        }
        for y in 0..<(rows - 1) { for x in 0..<(columns - 1) {
            let a = indices[y * columns + x], b = indices[y * columns + x + 1]
            let c = indices[(y + 1) * columns + x], d = indices[(y + 1) * columns + x + 1]
            triangle(a,c,b); triangle(b,c,d)
        } }
        return MeshChunk(vertices: vertices, faces: faces)
    }
}

/// Replace repeated views in spatial tiles rather than stacking full-frame meshes.
/// Opposing surface normals occupy separate tiles, preserving thin objects.
final class DepthSurfaceFusion {
    private struct Key: Hashable { let position: VoxelKey; let direction: Int }
    private struct Entry { let id: UUID; let score: Float }
    private var entries: [Key: Entry] = [:]

    func integrate(_ mesh: MeshChunk, camera: SIMD3<Float>) -> [(UUID, MeshChunk)] {
        var groups: [Key: [SIMD3<UInt32>]] = [:], scores: [Key: Float] = [:]
        for face in mesh.faces {
            let a = mesh.vertices[Int(face.x)], b = mesh.vertices[Int(face.y)], c = mesh.vertices[Int(face.z)]
            let cross = simd_cross(b - a, c - a)
            guard simd_length_squared(cross) > 1e-16 else { continue }
            let normal = simd_normalize(cross), center = (a + b + c) / 3
            let axis = abs(normal.x) > abs(normal.y) ? (abs(normal.x) > abs(normal.z) ? 0 : 2) : (abs(normal.y) > abs(normal.z) ? 1 : 2)
            let key = Key(position: VoxelKey(center, size: 0.025), direction: axis * 2 + (normal[axis] >= 0 ? 1 : 0))
            let delta = camera - center
            let incidence = abs(simd_dot(normal, delta / max(0.001, simd_length(delta))))
            guard incidence > 0.15 else { continue }
            groups[key, default: []].append(face); scores[key, default: 0] += incidence * incidence
        }
        var updates: [(UUID, MeshChunk)] = []
        for (key, faces) in groups {
            let score = scores[key] ?? 0
            if let previous = entries[key], score <= previous.score * 1.15 { continue }
            let id = entries[key]?.id ?? UUID()
            var lookup: [UInt32: UInt32] = [:], vertices: [SIMD3<Float>] = []
            func vertex(_ index: UInt32) -> UInt32 {
                if let existing = lookup[index] { return existing }
                let output = UInt32(vertices.count); lookup[index] = output; vertices.append(mesh.vertices[Int(index)]); return output
            }
            let remapped = faces.map { SIMD3(vertex($0.x),vertex($0.y),vertex($0.z)) }
            entries[key] = Entry(id: id, score: score)
            updates.append((id, MeshChunk(vertices: vertices, faces: remapped)))
        }
        return updates
    }
}
