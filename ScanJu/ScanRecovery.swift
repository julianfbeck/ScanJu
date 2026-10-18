import Foundation
import RoomPlan
import simd

struct CaptureDraft: Codable, Identifiable {
    let id: UUID
    let date: Date
    let mode: CaptureMode
    let quality: ScanQuality
    var duration: Double
    var saved: Date
}

/// Sensor data is committed during recording, before processing or ZIP export.
final class CaptureCheckpoint {
    let directory: URL
    private var draft: CaptureDraft

    init(id: UUID, mode: CaptureMode, quality: ScanQuality, directory: URL) throws {
        self.directory = directory
        draft = CaptureDraft(id: id, date: Date(), mode: mode, quality: quality, duration: 0, saved: Date())
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("checkpoint/mesh"), withIntermediateDirectories: true)
        try saveMetadata(duration: 0)
    }

    func saveMesh(_ mesh: MeshChunk, id: UUID) throws {
        var data = Data("SJM1".utf8)
        data.appendLE(UInt32(mesh.vertices.count)); data.appendLE(UInt32(mesh.faces.count))
        for v in mesh.vertices { data.appendFloat(v.x); data.appendFloat(v.y); data.appendFloat(v.z) }
        for f in mesh.faces { data.appendLE(f.x); data.appendLE(f.y); data.appendLE(f.z) }
        try data.write(to: directory.appendingPathComponent("checkpoint/mesh/\(id.uuidString).bin"), options: .atomic)
    }

    func removeMesh(id: UUID) throws {
        let url = directory.appendingPathComponent("checkpoint/mesh/\(id.uuidString).bin")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func finish(duration: Double) throws {
        try saveMetadata(duration: duration)
    }

    func saveMetadata(duration: Double) throws {
        draft.duration = duration; draft.saved = Date()
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent("CaptureDraft.json"), options: .atomic)
    }

    static func readMesh(_ url: URL) throws -> MeshChunk {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, data.prefix(4) == Data("SJM1".utf8) else { throw ScanFailure.message("Invalid mesh checkpoint.") }
        return try data.withUnsafeBytes { bytes in
            func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }
            let vertexCount = Int(u32(4)), faceCount = Int(u32(8))
            guard vertexCount <= 5_000_000, faceCount <= 5_000_000,
                  data.count == 12 + vertexCount * 12 + faceCount * 12 else { throw ScanFailure.message("Incomplete mesh checkpoint.") }
            let vertices = (0..<vertexCount).map { i in SIMD3(f32(12 + i * 12), f32(16 + i * 12), f32(20 + i * 12)) }
            let faces = (0..<faceCount).map { i in
                let offset = 12 + vertexCount * 12 + i * 12
                return SIMD3(u32(offset), u32(offset + 4), u32(offset + 8))
            }
            guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                  faces.allSatisfy({ Int(max($0.x, max($0.y, $0.z))) < vertexCount }) else { throw ScanFailure.message("Invalid mesh checkpoint indices.") }
            return MeshChunk(vertices: vertices, faces: faces)
        }
    }

}

struct RecoverableScan: Identifiable {
    let id: UUID
    let date: Date
    let record: ScanRecord?
    let draft: CaptureDraft?
    var title: String { record == nil ? "Interrupted capture" : "Export interrupted" }
    var directory: URL { ScanStore.root.appendingPathComponent(id.uuidString) }
}

enum ScanRecovery {
    static func candidates() -> [RecoverableScan] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: ScanStore.root, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { directory in
            if let data = try? Data(contentsOf: directory.appendingPathComponent("scan.json")),
               let record = try? JSONDecoder().decode(ScanRecord.self, from: data) {
                guard !FileManager.default.fileExists(atPath: record.archive.path) else { return nil }
                return RecoverableScan(id: record.id, date: record.date, record: record, draft: nil)
            }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("CaptureDraft.json")),
                  let draft = try? JSONDecoder().decode(CaptureDraft.self, from: data) else { return nil }
            return RecoverableScan(id: draft.id, date: draft.date, record: nil, draft: draft)
        }.sorted { $0.date > $1.date }
    }

    static func recover(_ candidate: RecoverableScan, progress: (String, Double) -> Void) throws -> ScanRecord {
        if let record = candidate.record { return try repairExport(record, progress: progress) }
        guard let draft = candidate.draft else { throw ScanFailure.message("No saved capture was found.") }
        let directory = candidate.directory
        progress("Restoring saved depth geometry", 0.02)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("checkpoint/mesh"), includingPropertiesForKeys: nil)) ?? []
        var mesh: [MeshChunk] = [], damaged = 0
        for url in urls {
            do { mesh.append(try CaptureCheckpoint.readMesh(url)) } catch { damaged += 1 }
        }
        let cloud = try PointCloudStore(directory: directory.appendingPathComponent("checkpoint/points"), voxelSize: draft.mode.voxelSize(draft.quality))
        let frames = ((try? Data(contentsOf: directory.appendingPathComponent("cameras.json")))
            .flatMap { try? JSONDecoder().decode([CameraSample].self, from: $0) } ?? []).filter { frame in
                [frame.image, frame.depth, frame.confidence].allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            }
        let room = (try? Data(contentsOf: directory.appendingPathComponent("checkpoint/Room.json")))
            .flatMap { try? JSONDecoder().decode(CapturedRoom.self, from: $0) }
        guard cloud.count > 0 || !mesh.isEmpty else { throw ScanFailure.message("The capture ended before depth geometry was saved. Any camera source files are retained in Files.") }
        var notes = ["Recovered from saved capture data after an interruption. The most recent unsaved observations may be missing."]
        if damaged > 0 { notes.append("\(damaged) incomplete mesh checkpoints were skipped; all other saved data was retained.") }
        return try ScanProcessor.process(id: draft.id, mode: draft.mode, quality: draft.quality, duration: draft.duration,
            points: [], pointCloud: cloud, mesh: mesh, frames: frames, room: room, notes: notes, directory: directory, progress: progress)
    }

    static func repairExport(_ record: ScanRecord, progress: (String, Double) -> Void) throws -> ScanRecord {
        var record = record
        let directory = record.directory
        progress("Finishing the saved scan export", 0)
        // Never re-run reconstruction or decode textures just to finish a ZIP.
        record.files = try ScanProcessor.relativeFiles(directory).filter { $0 != "ScanJu.zip" }
        if !record.files.contains("scan.json") { record.files.append("scan.json") }
        try ScanStore.save(record)
        try ZipArchive.create(at: record.archive, root: directory, files: record.files) { progress("Packaging saved data", $0) }
        progress("Scan ready", 1)
        return record
    }
}
