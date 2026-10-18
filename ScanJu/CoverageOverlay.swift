import SceneKit
import simd
import UIKit

/// Coverage describes measured geometry, rather than an estimated percentage of a room.
enum CoverageFocus: Equatable {
    case searching, captured, unscanned, tooClose, outOfRange, trackingLimited

    var title: String {
        switch self {
        case .searching: return "Finding a surface"
        case .captured: return "Mesh captured"
        case .unscanned: return "Not captured yet"
        case .tooClose: return "Step back slightly"
        case .outOfRange: return "Move closer"
        case .trackingLimited: return "Tracking paused"
        }
    }

    static func classify(meshDepth: Float?, measuredDepth: Float?, tracking: Bool,
                         range: ClosedRange<Float> = 0.2...5, tolerance: Float = 0.12) -> Self {
        guard tracking else { return .trackingLimited }
        let depth = measuredDepth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let meshDepth, meshDepth.isFinite, meshDepth > 0 {
            // A previously scanned wall behind a new foreground surface is not
            // coverage of that foreground surface. Allow for LiDAR/mesh noise.
            if let depth, depth + tolerance < meshDepth { return .unscanned }
            return .captured
        }
        guard let depth else { return .searching }
        if depth < range.lowerBound { return .tooClose }
        return depth <= range.upperBound ? .unscanned : .outOfRange
    }
}

enum CoverageOverlay {
    static let category = 1 << 1

    static func geometry(_ mesh: MeshChunk) -> SCNGeometry {
        // Separate the corners of each triangle to carry barycentric coordinates.
        // This draws a consistent, antialiased mesh grid without a second pass.
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], coordinates: [CGPoint] = []
        vertices.reserveCapacity(mesh.faces.count * 3)
        normals.reserveCapacity(mesh.faces.count * 3)
        coordinates.reserveCapacity(mesh.faces.count * 3)
        for face in mesh.faces {
            let a = mesh.vertices[Int(face.x)], b = mesh.vertices[Int(face.y)], c = mesh.vertices[Int(face.z)]
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length_squared(cross) > 0.00000001 ? simd_normalize(cross) : SIMD3<Float>(0, 1, 0)
            vertices += [SCNVector3(a), SCNVector3(b), SCNVector3(c)]
            normals += Array(repeating: SCNVector3(normal), count: 3)
            coordinates += [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), .zero]
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: coordinates)], elements: [
                SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .triangles)
            ])
    }

    // Pull the display geometry slightly toward the camera along each view ray.
    // ARSCNView's environment depth prepass otherwise hides coplanar coverage.
    // Depth testing stays enabled so nearer surfaces occlude farther mesh patches.
    // This affects only rendering; stored vertices and exports retain measured positions.
    private static let depthBias = """
        float3 camera = scn_frame.inverseViewTransform[3].xyz;
        _geometry.position.xyz = camera + (_geometry.position.xyz - camera) * 0.985;
        """

    static func material(wireframe: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.25, green: 0.91, blue: 0.72, alpha: 1)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = true
        if wireframe {
            material.fillMode = .lines
            material.shaderModifiers = [.geometry: depthBias]
        } else {
            material.shaderModifiers = [
                .geometry: """
                    #pragma varyings
                    float2 scanBarycentric;
                    float scanShade;
                    #pragma body
                    \(depthBias)
                    out.scanBarycentric = _geometry.texcoords[0];
                    out.scanShade = 0.72 + 0.28 * abs(dot(_geometry.normal, normalize(float3(0.3, 0.8, 0.5))));
                    """,
                .fragment: """
                    #pragma opaque
                    #pragma body
                    float3 bary = float3(in.scanBarycentric, 1.0 - in.scanBarycentric.x - in.scanBarycentric.y);
                    float3 edge = smoothstep(float3(0.0), max(fwidth(bary) * 1.6, float3(0.00001)), bary);
                    float interior = min(min(edge.x, edge.y), edge.z);
                    _output.color = float4(mix(float3(0.025, 0.24, 0.20),
                        float3(0.25, 0.91, 0.72) * in.scanShade, interior), 1.0);
                    """
            ]
        }
        return material
    }
}
