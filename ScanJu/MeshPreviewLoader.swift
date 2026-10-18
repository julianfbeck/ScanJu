import Foundation
import ImageIO
import SceneKit
import simd
import UIKit

/// Read geometry without letting a scene importer decode every full-size JPEG.
/// Only thumbnail textures enter RAM. Original images and export geometry are untouched.
enum MeshPreviewLoader {
    static func load(directory: URL) throws -> SCNScene {
        let frames = (try? Data(contentsOf: directory.appendingPathComponent("cameras.json")))
            .flatMap { try? JSONDecoder().decode([CameraSample].self, from: $0) } ?? []
        let paths = Dictionary(uniqueKeysWithValues: frames.enumerated().map { ("camera_\($0.offset)", $0.element.image) })
        let maximumSide = min(2048, max(64, Int(sqrt(16_000_000.0 / Double(max(1, frames.count))))))
        var materials: [String: SCNMaterial] = [:]
        func material(_ name: String) throws -> SCNMaterial {
            if let cached = materials[name] { return cached }
            try Task.checkCancellation()
            let result = SCNMaterial()
            result.name = name; result.lightingModel = .constant; result.isDoubleSided = true
            result.diffuse.contents = UIColor(red: 0.48, green: 0.56, blue: 0.55, alpha: 1)
            if let path = paths[name] {
                result.diffuse.contents = autoreleasepool { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(path) as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
                            kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
                    return UIImage(cgImage: image)
                }
            }
            materials[name] = result
            return result
        }
        let scene = SCNScene()
        var positions: [SIMD3<Float>] = [], textureCoordinates: [SIMD2<Float>] = []
        var vertices: [SCNVector3] = [], uvs: [CGPoint] = []
        var currentMaterial = "unobserved"
        func flush() throws {
            guard !vertices.isEmpty else { return }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uvs)],
                elements: [SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .triangles)])
            geometry.materials = [try material(currentMaterial)]
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
            vertices.removeAll(keepingCapacity: true); uvs.removeAll(keepingCapacity: true)
        }
        try lines(directory.appendingPathComponent("Mesh.obj")) { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let kind = fields.first else { return }
            switch kind {
            case "v":
                guard fields.count >= 4, let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3]) else { return }
                positions.append(SIMD3(x,y,z))
            case "vt":
                guard fields.count >= 3, let u = Float(fields[1]), let v = Float(fields[2]) else { return }
                textureCoordinates.append(SIMD2(u,v))
            case "usemtl":
                try flush(); currentMaterial = fields.count > 1 ? String(fields[1]) : "unobserved"
            case "f":
                guard fields.count == 4 else { return }
                var corners: [(SCNVector3, CGPoint)] = []
                for field in fields.dropFirst() {
                    let indices = field.split(separator: "/", omittingEmptySubsequences: false)
                    guard let first = indices.first, let v = Int(first), v > 0, v <= positions.count else { return }
                    var uv = CGPoint.zero
                    if indices.count > 1, let t = Int(indices[1]), t > 0, t <= textureCoordinates.count {
                        let value = textureCoordinates[t - 1]; uv = CGPoint(x: CGFloat(value.x), y: CGFloat(value.y))
                    }
                    corners.append((SCNVector3(positions[v - 1]), uv))
                }
                vertices.append(contentsOf: corners.map(\.0)); uvs.append(contentsOf: corners.map(\.1))
                if vertices.count >= 60_000 { try flush() }
            default: break
            }
        }
        try flush()
        guard !scene.rootNode.childNodes.isEmpty else { throw ScanFailure.message("No mesh triangles are available. Choose Points to inspect saved LiDAR data.") }
        return scene
    }

    private static func lines(_ url: URL, consume: (Substring) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty else { return false }
            pending.append(chunk)
            var cursor = pending.startIndex
            while let newline = pending[cursor...].firstIndex(of: 10) {
                let line = String(decoding: pending[cursor..<newline], as: UTF8.self)
                try consume(line[...]); cursor = newline + 1
            }
            pending = Data(pending[cursor...])
            return true
        }) {}
        if !pending.isEmpty { let line = String(decoding: pending, as: UTF8.self); try consume(line[...]) }
    }
}
