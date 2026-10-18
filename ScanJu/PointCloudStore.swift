import Foundation
import simd

/// A bounded RAM cache over persistent voxel tiles. The point cloud has no fixed
/// point-count ceiling; older tiles move to disk instead of dropping new samples.
final class PointCloudStore {
    private struct TileKey: Hashable {
        let x: Int32, y: Int32, z: Int32
        init(_ voxel: VoxelKey) {
            func floorDiv(_ value: Int32) -> Int32 { value >= 0 ? value / 64 : (value + 1) / 64 - 1 }
            x = floorDiv(voxel.x); y = floorDiv(voxel.y); z = floorDiv(voxel.z)
        }
        var name: String { "\(x)_\(y)_\(z).bin" }
    }
    private struct Tile {
        var points: [VoxelKey: ColoredPoint]
        var used: Int
        var dirty: Bool
    }
    let directory: URL
    let voxelSize: Float
    private let cacheLimit: Int
    private var tiles: [TileKey: Tile] = [:]
    private var tick = 0, cachedPoints = 0
    private(set) var count = 0

    init(directory: URL, voxelSize: Float, cacheLimit: Int = 200_000) throws {
        self.directory = directory; self.voxelSize = voxelSize; self.cacheLimit = cacheLimit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "bin" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 8) ?? Data()
            guard data.count == 8, data.prefix(4) == Data("SJP2".utf8) else { throw ScanFailure.message("Invalid point-cloud tile.") }
            count += data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        }
    }

    func integrate(position: SIMD3<Float>, color: SIMD3<Float>) throws {
        let key = VoxelKey(position, size: voxelSize), tileKey = TileKey(key)
        if tiles[tileKey] == nil {
            let url = directory.appendingPathComponent(tileKey.name)
            let points = FileManager.default.fileExists(atPath: url.path) ? try Self.read(url, voxelSize: voxelSize) : [:]
            tiles[tileKey] = Tile(points: points, used: tick, dirty: false)
            cachedPoints += points.count
        }
        tick += 1
        // Mutate the nested value in place: copying a whole tile per observation
        // would turn point fusion into quadratic work.
        tiles[tileKey]!.used = tick
        tiles[tileKey]!.dirty = true
        if var point = tiles[tileKey]!.points[key] {
            let weight = min(point.weight, 24)
            point.position = (point.position * weight + position) / (weight + 1)
            point.color = (point.color * weight + color) / (weight + 1)
            point.weight = weight + 1
            tiles[tileKey]!.points[key] = point
        } else {
            tiles[tileKey]!.points[key] = ColoredPoint(position: position, color: color, weight: 1)
            count += 1; cachedPoints += 1
        }
    }

    func trimCache() throws {
        for key in tiles.keys.sorted(by: { tiles[$0]!.used < tiles[$1]!.used }) {
            guard cachedPoints > cacheLimit else { break }
            try save(key)
            cachedPoints -= tiles[key]!.points.count
            tiles.removeValue(forKey: key)
        }
    }

    func flush(releaseCache: Bool = false) throws {
        for key in Array(tiles.keys) { try save(key) }
        if releaseCache { tiles.removeAll(); cachedPoints = 0 }
    }

    private func save(_ key: TileKey) throws {
        guard let tile = tiles[key], tile.dirty else { return }
        try autoreleasepool {
            var data = Data("SJP2".utf8)
            data.appendLE(UInt32(tile.points.count))
            for (key, point) in tile.points {
                data.appendLE(UInt32(bitPattern: key.x)); data.appendLE(UInt32(bitPattern: key.y)); data.appendLE(UInt32(bitPattern: key.z))
                data.appendFloat(point.position.x); data.appendFloat(point.position.y); data.appendFloat(point.position.z)
                data.appendFloat(point.color.x); data.appendFloat(point.color.y); data.appendFloat(point.color.z); data.appendFloat(point.weight)
            }
            try data.write(to: directory.appendingPathComponent(key.name), options: .atomic)
        }
        tiles[key]!.dirty = false
    }

    private static func read(_ url: URL, voxelSize: Float) throws -> [VoxelKey: ColoredPoint] {
        let data = try Data(contentsOf: url)
        guard data.count >= 8, data.prefix(4) == Data("SJP2".utf8) else { throw ScanFailure.message("Invalid point-cloud tile.") }
        return try data.withUnsafeBytes { bytes in
            func f(_ i: Int) -> Float { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self))) }
            let count = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            guard count <= 262_144, data.count == 8 + count * 40 else { throw ScanFailure.message("Incomplete point-cloud tile.") }
            var points: [VoxelKey: ColoredPoint] = [:]
            points.reserveCapacity(count)
            for i in 0..<count {
                let j = 8 + i * 40
                func keyPart(_ offset: Int) -> Int32 { Int32(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
                let key = VoxelKey(x: keyPart(j), y: keyPart(j + 4), z: keyPart(j + 8))
                let position = SIMD3(f(j + 12), f(j + 16), f(j + 20))
                let color = SIMD3(f(j + 24), f(j + 28), f(j + 32)), weight = f(j + 36)
                guard [position.x, position.y, position.z, color.x, color.y, color.z, weight].allSatisfy(\.isFinite), weight > 0 else { throw ScanFailure.message("Invalid saved point.") }
                points[key] = ColoredPoint(position: position, color: color, weight: weight)
            }
            return points
        }
    }

    func writePLY(to output: URL, progress: (Double) -> Void) throws {
        try flush(releaseCache: true)
        let temporary = output.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        let header = "ply\nformat binary_little_endian 1.0\ncomment ScanJu meters Y-up\nelement vertex \(count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        try handle.write(contentsOf: Data(header.utf8))
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bin" }
        var written = 0
        for url in urls {
            try autoreleasepool {
                let points = try Self.read(url, voxelSize: voxelSize)
                var data = Data(capacity: points.count * 15)
                for point in points.values {
                    data.appendFloat(point.position.x); data.appendFloat(point.position.y); data.appendFloat(point.position.z)
                    data.append(UInt8(clamping: Int(point.color.x.rounded())))
                    data.append(UInt8(clamping: Int(point.color.y.rounded())))
                    data.append(UInt8(clamping: Int(point.color.z.rounded())))
                }
                try handle.write(contentsOf: data)
                written += points.count; progress(Double(written) / Double(max(1, count)))
            }
        }
        try handle.synchronize(); try handle.close()
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: output) }
        progress(1)
    }
}
