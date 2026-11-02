import XCTest
import Combine
import simd
import SceneKit
import UIKit
@testable import ScanJu

final class ScanJuTests: XCTestCase {
    @MainActor
    func testCaptureContinuesPastFourMinutesAndMemoryWarning() async {
        let engine = CaptureEngine(mode: .surface, quality: .detail)
        engine.phase = .capturing
        engine.updateCaptureStatus(at: Date().addingTimeInterval(86_400))
        XCTAssertGreaterThanOrEqual(engine.elapsed, 86_399)
        XCTAssertEqual(engine.phase, .capturing)

        let checkpointed = expectation(description: "Memory warning flushes the checkpoint")
        let subscription = engine.$savedAt.compactMap { $0 }.prefix(1).sink { _ in checkpointed.fulfill() }
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await fulfillment(of: [checkpointed], timeout: 5)
        XCTAssertEqual(engine.phase, .capturing)
        subscription.cancel()
        engine.phase = .ready
    }

    func testOnlyLowStorageTriggersTheDiskReserve() throws {
        XCTAssertNoThrow(try CaptureEngine.checkRemainingStorage(150_000_001))
        XCTAssertNoThrow(try CaptureEngine.checkRemainingStorage(Int64.max))
        for bytes: Int64 in [150_000_000, 0, -1] {
            XCTAssertThrowsError(try CaptureEngine.checkRemainingStorage(bytes)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Saved capture data is retained"))
            }
        }
    }

    func testZIP64DirectoryPreservesLargeOffsetsAndEntryCounts() {
        let offset = UInt64(UInt32.max) + 1234, size = UInt64(UInt32.max) + 5678
        let end = ZipArchive.directoryEnd(entryCount: 70_000, size: size, offset: offset, zip64: true)
        func u64(_ index: Int) -> UInt64 {
            end.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt64.self)) }
        }
        XCTAssertEqual(end.count, 98)
        XCTAssertEqual(Array(end.prefix(4)), [0x50, 0x4b, 0x06, 0x06])
        XCTAssertEqual(u64(24), 70_000)
        XCTAssertEqual(u64(32), 70_000)
        XCTAssertEqual(u64(40), size)
        XCTAssertEqual(u64(48), offset)
        XCTAssertEqual(u64(64), offset + size)
        XCTAssertEqual(Array(end.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
        XCTAssertEqual(Array(end.suffix(14).prefix(4)), [0xff, 0xff, 0xff, 0xff])
    }

    func testCoverageDoesNotMarkAnUnmeshedForegroundSurfaceAsCaptured() {
        XCTAssertEqual(CoverageFocus.classify(meshDepth: 3, measuredDepth: 1, tracking: true), .unscanned)
        XCTAssertEqual(CoverageFocus.classify(meshDepth: 1.05, measuredDepth: 1, tracking: true), .captured)
        XCTAssertEqual(CoverageFocus.classify(meshDepth: nil, measuredDepth: 1, tracking: true), .unscanned)
        XCTAssertEqual(CoverageFocus.classify(meshDepth: nil, measuredDepth: 6, tracking: true), .outOfRange)
        XCTAssertEqual(CoverageFocus.classify(meshDepth: nil, measuredDepth: 0.1, tracking: true), .tooClose)
        XCTAssertEqual(CoverageFocus.classify(meshDepth: nil, measuredDepth: .nan, tracking: true), .searching)
        XCTAssertEqual(CoverageFocus.classify(meshDepth: 1, measuredDepth: 1, tracking: false), .trackingLimited)
    }

    func testDepthUnprojectionAndProjectionRoundTripWithPose() throws {
        let k = simd_float3x3(SIMD3(100,0,0), SIMD3(0,100,0), SIMD3(50,40,1))
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(1,2,3,1)
        let world = ScanMath.unproject(x: 70, y: 30, depth: 2, intrinsics: k, cameraToWorld: pose)
        XCTAssertEqual(world.x, 1.4, accuracy: 0.0001)
        XCTAssertEqual(world.y, 2.2, accuracy: 0.0001)
        XCTAssertEqual(world.z, 1, accuracy: 0.0001)
        let uv = try XCTUnwrap(ScanMath.project(world, worldToCamera: pose.inverse, intrinsics: k, width: 100, height: 80))
        XCTAssertEqual(uv.x, 0.7, accuracy: 0.0001)
        XCTAssertEqual(uv.y, 0.625, accuracy: 0.0001)
        XCTAssertNil(ScanMath.project(SIMD3(1,2,4), worldToCamera: pose.inverse, intrinsics: k, width: 100, height: 80))
    }

    func testVoxelGridHandlesNegativeCoordinates() {
        XCTAssertNotEqual(VoxelKey(SIMD3(-0.001,0,0), size: 0.01), VoxelKey(SIMD3(0.001,0,0), size: 0.01))
        XCTAssertEqual(VoxelKey(SIMD3(0.001,0,0), size: 0.01), VoxelKey(SIMD3(0.009,0,0), size: 0.01))
    }

    func testConcaveFloorAreaAndWinding() {
        let polygon: [SIMD2<Float>] = [SIMD2(0,0),SIMD2(3,0),SIMD2(3,1),SIMD2(1,1),SIMD2(1,3),SIMD2(0,3)]
        XCTAssertEqual(ScanMath.polygonArea(polygon), 5, accuracy: 0.0001)
        XCTAssertEqual(ScanMath.polygonArea(polygon.reversed()), 5, accuracy: 0.0001)
    }

    func testPLYBinaryRoundTripPreservesColorAndCoordinates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cloud.ply")
        let expected = ColoredPoint(position: SIMD3(-1.25,2.5,0.125), color: SIMD3(11,99,255), weight: 1)
        try ScanProcessor.writePLY([expected], to: url)
        let actual = try XCTUnwrap(PointPreviewReader.read(url).first)
        XCTAssertEqual(actual.position, expected.position)
        XCTAssertEqual(actual.color, expected.color)
    }

    func testZIPCentralDirectoryAndCRC() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = Data("123456789".utf8)
        XCTAssertEqual(ZipArchive.crc32(content) ^ 0xffffffff, 0xcbf43926)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try content.write(to: directory.appendingPathComponent("frames/test.depth"))
        let output = directory.appendingPathComponent("test.zip")
        try ZipArchive.create(at: output, root: directory, files: ["frames/test.depth"])
        let data = try Data(contentsOf: output)
        XCTAssertEqual(Array(data.prefix(4)), [0x50,0x4b,0x03,0x04])
        XCTAssertNotNil(data.range(of: content))
        XCTAssertEqual(Array(data.suffix(22).prefix(4)), [0x50,0x4b,0x05,0x06])
    }

    func testOBJKeepsUnobservedFacesWithoutInventedTexture() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mesh = MeshChunk(vertices: [SIMD3(0,0,-1),SIMD3(1,0,-1),SIMD3(0,1,-1)], faces: [SIMD3(0,1,2)])
        let count = try ScanProcessor.writeOBJ(mesh: [mesh], frames: [], directory: directory)
        XCTAssertEqual(count, 0)
        let text = try String(contentsOf: directory.appendingPathComponent("Mesh.obj"), encoding: .utf8)
        XCTAssertTrue(text.contains("usemtl unobserved"))
        XCTAssertTrue(text.contains("f 1 2 3"))
    }

    func testTextureProjectionRejectsOccludedFaces() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mesh = MeshChunk(vertices: [SIMD3<Float>(-0.1,-0.1,-1),SIMD3(0.1,-0.1,-1),SIMD3(0,0.1,-1)], faces: [SIMD3(0,1,2)])
        let camera = CameraSample(image: "frames/camera.jpg", depth: "depth.bin", confidence: "confidence.bin", timestamp: 0,
            width: 100, height: 100, depthWidth: 10, depthHeight: 10,
            intrinsics: [100,0,0,0,100,0,50,50,1], cameraToWorld: flatten(matrix_identity_float4x4), tracking: "normal")
        var depth = Data()
        for _ in 0..<100 { depth.appendFloat(1) }
        try depth.write(to: directory.appendingPathComponent("depth.bin"))
        try Data(repeating: 2, count: 100).write(to: directory.appendingPathComponent("confidence.bin"))
        XCTAssertEqual(try ScanProcessor.writeOBJ(mesh: [mesh], frames: [camera], directory: directory), 1)
        let text = try String(contentsOf: directory.appendingPathComponent("Mesh.obj"), encoding: .utf8)
        XCTAssertTrue(text.contains("usemtl camera_0"))
        XCTAssertTrue(text.contains("f 1/1 2/2 3/3"))
        depth = Data()
        for _ in 0..<100 { depth.appendFloat(0.5) }
        try depth.write(to: directory.appendingPathComponent("depth.bin"))
        XCTAssertEqual(try ScanProcessor.writeOBJ(mesh: [mesh], frames: [camera], directory: directory), 0)
    }

    func testCompleteProcessingRetainsMeshAndCreatesShareableArchive() throws {
        let id = UUID()
        let directory = ScanStore.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mesh = MeshChunk(vertices: [SIMD3<Float>(0,0,-1),SIMD3(1,0,-1),SIMD3(0,1,-1)], faces: [SIMD3(0,1,2)])
        let cloud = [ColoredPoint(position: SIMD3(0,0,-1), color: SIMD3(50,100,150), weight: 1)]
        let record = try ScanProcessor.process(id: id, mode: .surface, quality: .detail, duration: 1,
            points: cloud, mesh: [mesh], frames: [], room: nil, notes: [], directory: directory, progress: { _, _ in })
        XCTAssertTrue(record.files.contains("Mesh.mtl"))
        XCTAssertTrue(record.files.contains("Mesh.obj"))
        XCTAssertTrue(record.files.contains("PointCloud.ply"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.archive.path))
        for file in record.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path), file)
        }
        XCTAssertEqual(ScanStore.load().first(where: { $0.id == id })?.triangleCount, 1)
    }

    func testSceneKitLoadsCameraTextureAlongsideNeutralFaces() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mesh = MeshChunk(vertices: [SIMD3<Float>(-0.1,-0.1,-1),SIMD3(0.1,-0.1,-1),SIMD3(0,0.1,-1),
            SIMD3(2,0,-1),SIMD3(3,0,-1),SIMD3(2,1,-1)], faces: [SIMD3(0,1,2),SIMD3(3,4,5)])
        let camera = CameraSample(image: "frames/camera.jpg", depth: "depth.bin", confidence: "confidence.bin", timestamp: 0,
            width: 100, height: 100, depthWidth: 10, depthHeight: 10,
            intrinsics: [100,0,0,0,100,0,50,50,1], cameraToWorld: flatten(matrix_identity_float4x4), tracking: "normal")
        var depth = Data()
        for _ in 0..<100 { depth.appendFloat(1) }
        try depth.write(to: directory.appendingPathComponent("depth.bin"))
        try Data(repeating: 2, count: 100).write(to: directory.appendingPathComponent("confidence.bin"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try XCTUnwrap(image.jpegData(compressionQuality: 0.94)).write(to: directory.appendingPathComponent(camera.image))
        try JSONEncoder().encode([camera]).write(to: directory.appendingPathComponent("cameras.json"))
        XCTAssertEqual(try ScanProcessor.writeOBJ(mesh: [mesh], frames: [camera], directory: directory), 1)
        let scene = try ScanProcessor.loadTexturedScene(directory: directory)
        var materials: [SCNMaterial] = []
        scene.rootNode.enumerateChildNodes { node, _ in materials += node.geometry?.materials ?? [] }
        XCTAssertTrue(materials.contains { $0.name == "camera_0" }, materials.compactMap(\.name).joined(separator: ","))
        XCTAssertTrue(materials.contains { $0.name == "unobserved" })
        let texture = try XCTUnwrap(materials.first { $0.name == "camera_0" }?.diffuse.contents)
        XCTAssertTrue(texture is UIImage, "Camera material must resolve its nested image path: \(texture)")
        let output = directory.appendingPathComponent("Test.usdz")
        try ZipArchive.create(at: output, root: directory, files: ["Mesh.usda", camera.image], alignment: 64)
        let usdData = try Data(contentsOf: output)
        XCTAssertEqual(Array(usdData.prefix(4)), [0x50,0x4b,0x03,0x04], "USDZ must be a ZIP archive")
        XCTAssertNotNil(usdData.range(of: Data("camera.jpg".utf8)), "USDZ must embed imagery")
        let imported = try SCNScene(url: output, options: nil)
        var geometries: [SCNGeometry] = []
        imported.rootNode.enumerateChildNodes { node, _ in if let geometry = node.geometry { geometries.append(geometry) } }
        XCTAssertEqual(geometries.reduce(0) { $0 + $1.elements.reduce(0) { $0 + $1.primitiveCount } }, 2)
        XCTAssertTrue(geometries.contains { !$0.sources(for: .texcoord).isEmpty })
    }

    func testUSDZEntriesAreStoredAndAlignedIncludingSmallPadding() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = [String(repeating: "a", count: 31), "image.jpg", "third.jpg"]
        for name in names { try Data(repeating: 7, count: 137).write(to: directory.appendingPathComponent(name)) }
        let output = directory.appendingPathComponent("test.usdz")
        try ZipArchive.create(at: output, root: directory, files: names, alignment: 64)
        let data = try Data(contentsOf: output)
        func u16(_ offset: Int) -> Int { Int(data[offset]) + Int(data[offset + 1]) * 256 }
        var cursor = 0
        for name in names {
            XCTAssertEqual(Array(data[cursor..<(cursor + 4)]), [0x50,0x4b,0x03,0x04])
            XCTAssertEqual(u16(cursor + 8), 0)
            let length = u16(cursor + 26), extra = u16(cursor + 28)
            XCTAssertEqual(String(decoding: data[(cursor + 30)..<(cursor + 30 + length)], as: UTF8.self), name)
            let start = cursor + 30 + length + extra
            XCTAssertEqual(start % 64, 0)
            XCTAssertEqual(data[start..<(start + 137)], Data(repeating: 7, count: 137))
            cursor = start + 137
        }
    }

    func testPointCloudGrowsBeyondOldLimitAndSurvivesEvictionAndRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PointCloudStore(directory: directory, voxelSize: 0.01, cacheLimit: 40_000)
        // Tile-ordered input exercises eviction without repeatedly thrashing tiles.
        for tile in 0..<4 {
            for x in 0..<64 { for y in 0..<64 { for z in 0..<64 {
                let position = SIMD3(Float(tile * 64 + x) * 0.01 + 0.005,
                                     Float(y) * 0.01 + 0.005, Float(z) * 0.01 + 0.005)
                try store.integrate(position: position, color: SIMD3(10,20,30))
            } } }
            try store.trimCache()
        }
        let negative = SIMD3<Float>(-0.005,-0.645,-1.285)
        try store.integrate(position: negative, color: SIMD3(20,30,40))
        try store.flush(releaseCache: true)
        XCTAssertEqual(store.count, 1_048_577)
        let restored = try PointCloudStore(directory: directory, voxelSize: 0.01, cacheLimit: 40_000)
        try restored.integrate(position: negative, color: SIMD3(40,50,60))
        XCTAssertEqual(restored.count, 1_048_577, "Restart must preserve voxel identity, including negative coordinates")
        let ply = directory.appendingPathComponent("points.ply")
        var values: [Double] = []
        try restored.writePLY(to: ply) { values.append($0) }
        let data = try Data(contentsOf: ply, options: .mappedIfSafe)
        let end = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
        XCTAssertEqual(data.count - end.upperBound, 1_048_577 * 15)
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        let preview = try PointPreviewReader.read(ply)
        XCTAssertTrue(preview.contains { $0.position.x > 1.9 }, "Points beyond the former limit must reach the exported PLY")
    }

    func testInterruptedCaptureRecoversSavedMeshAndPointsWithoutCamera() throws {
        let id = UUID(), anchorID = UUID()
        let directory = ScanStore.root.appendingPathComponent(id.uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = try CaptureCheckpoint(id: id, mode: .surface, quality: .detail, directory: directory)
        let mesh = MeshChunk(vertices: [SIMD3<Float>(0,0,-1),SIMD3(1,0,-1),SIMD3(0,1,-1)], faces: [SIMD3(0,1,2)])
        try checkpoint.saveMesh(mesh, id: anchorID)
        let cloud = try PointCloudStore(directory: directory.appendingPathComponent("checkpoint/points"), voxelSize: 0.008)
        try cloud.integrate(position: SIMD3(0,0,-1), color: SIMD3(20,40,60))
        try cloud.flush(releaseCache: true)
        try checkpoint.finish(duration: 12)
        // A damaged separate anchor must not make valid saved geometry unusable.
        try Data("SJM1".utf8).write(to: directory.appendingPathComponent("checkpoint/mesh/broken.bin"))
        let candidate = try XCTUnwrap(ScanRecovery.candidates().first { $0.id == id })
        var fractions: [Double] = []
        let record = try ScanRecovery.recover(candidate) { _, fraction in fractions.append(fraction) }
        XCTAssertEqual(record.pointCount, 1)
        XCTAssertEqual(record.triangleCount, 1)
        XCTAssertEqual(record.duration, 12)
        XCTAssertEqual(record.frameCount, 0)
        XCTAssertTrue(record.notes.contains { $0.contains("incomplete mesh checkpoints") })
        XCTAssertFalse(record.files.contains { $0.hasPrefix("checkpoint/") || $0 == "CaptureDraft.json" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.archive.path))
        XCTAssertFalse(ScanRecovery.candidates().contains { $0.id == id })
        XCTAssertEqual(fractions.last, 1)
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testInterruptedExportRepairsArchiveAndPreservesSourceData() throws {
        let id = UUID(), directory = ScanStore.root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = [ColoredPoint(position: SIMD3(0,0,-1), color: SIMD3(50,100,150), weight: 1)]
        let record = try ScanProcessor.process(id: id, mode: .surface, quality: .detail, duration: 2,
            points: cloud, mesh: [], frames: [], room: nil, notes: [], directory: directory) { _, _ in }
        let source = try Data(contentsOf: directory.appendingPathComponent("PointCloud.ply"))
        try FileManager.default.removeItem(at: record.archive)
        try Data(repeating: 7, count: 4096).write(to: record.archive.appendingPathExtension("partial"))
        let candidate = try XCTUnwrap(ScanRecovery.candidates().first { $0.id == id })
        var fractions: [Double] = []
        let recovered = try ScanRecovery.recover(candidate) { _, fraction in fractions.append(fraction) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("PointCloud.ply")), source)
        XCTAssertFalse(recovered.files.contains { $0.hasSuffix(".partial") })
        XCTAssertEqual(try Data(contentsOf: recovered.archive).suffix(22).prefix(4), Data([0x50,0x4b,0x05,0x06]))
        XCTAssertFalse(ScanRecovery.candidates().contains { $0.id == id })
        XCTAssertEqual(fractions.last, 1)
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testStreamingZIPProgressAndAtomicReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 0x32, count: 3_000_000)
        try data.write(to: directory.appendingPathComponent("large.bin"))
        let output = directory.appendingPathComponent("archive.zip")
        try Data("previous".utf8).write(to: output)
        var fractions: [Double] = []
        try ZipArchive.create(at: output, root: directory, files: ["large.bin"]) { fractions.append($0) }
        XCTAssertGreaterThan(fractions.count, 10)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        let zip = try Data(contentsOf: output)
        XCTAssertEqual(zip[39..<(39 + data.count)], data)
        let checksum = zip.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 14, as: UInt32.self)) }
        XCTAssertEqual(checksum, ZipArchive.crc32(data) ^ 0xffffffff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("partial").path))
    }

    func testDeleteAllRemovesCompletedAndInterruptedDataWithinScanFolder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scans = directory.appendingPathComponent("Scans")
        for name in ["finished/frames/photo.jpg", "finished/ScanJu.zip", "interrupted/checkpoint/points/tile.bin", "interrupted/CaptureDraft.json"] {
            let file = scans.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1,2,3]).write(to: file)
        }
        let unrelated = directory.appendingPathComponent("other.txt")
        try Data("keep".utf8).write(to: unrelated)
        try ScanStore.removeAll(in: scans)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scans.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertNoThrow(try ScanStore.removeAll(in: scans))
    }

    func testTrueDepthCalibrationScalesAndRoundTripsLensDistortion() throws {
        // Constant radial magnification gives an exact inverse for this fixture.
        let calibration = DepthCalibration(matrix: [200,0,0,0,200,0,100,80,1],
            referenceWidth: 200, referenceHeight: 160, center: SIMD2(100,80),
            forward: [0.1,0.1], inverse: [-1 / 11,-1 / 11])
        let k = calibration.intrinsics(width: 100, height: 80)
        XCTAssertEqual(k[0][0], 100)
        XCTAssertEqual(k[2][1], 40)
        let rectified = calibration.rectified(SIMD2(72,29), width: 100, height: 80)
        XCTAssertEqual(rectified.x, 70, accuracy: 0.00001)
        XCTAssertEqual(rectified.y, 30, accuracy: 0.00001)
        let world = ScanMath.unproject(x: 72, y: 29, depth: 0.3, intrinsics: k,
            cameraToWorld: matrix_identity_float4x4, calibration: calibration, width: 100, height: 80)
        let uv = try XCTUnwrap(ScanMath.project(world, worldToCamera: matrix_identity_float4x4,
            intrinsics: k, width: 100, height: 80, calibration: calibration))
        XCTAssertEqual(uv.x, 0.72, accuracy: 0.00001)
        XCTAssertEqual(uv.y, 1 - 29 / 80.0, accuracy: 0.00001)
        let restored = try JSONDecoder().decode(DepthCalibration.self, from: JSONEncoder().encode(calibration))
        XCTAssertEqual(restored.forward, calibration.forward)
        XCTAssertEqual(restored.center, calibration.center)
    }

    func testOldCameraSamplesDecodeWithoutTrueDepthFields() throws {
        let camera = CameraSample(image: "a.jpg", depth: "a.depth", confidence: "a.confidence", timestamp: 0,
            width: 100, height: 80, depthWidth: 10, depthHeight: 8,
            intrinsics: [100,0,0,0,100,0,50,40,1], cameraToWorld: flatten(matrix_identity_float4x4), tracking: "normal")
        let data = try JSONEncoder().encode(camera)
        let restored = try JSONDecoder().decode(CameraSample.self, from: data)
        XCTAssertNil(restored.depthCalibration)
        XCTAssertNil(restored.confidenceSource)
        XCTAssertEqual(restored.depthSource, "sceneDepth")
        XCTAssertEqual(restored.calibration, camera.imageCalibration)
    }

    func testTrueDepthMeshRejectsHolesDepthEdgesAndInvalidRange() {
        let k = simd_float3x3(SIMD3(100,0,0),SIMD3(0,100,0),SIMD3(2,2,1))
        var pose = matrix_identity_float4x4; pose.columns.3 = SIMD4(1,2,3,1)
        let mesh = DepthSurfaceBuilder.mesh(depth: [Float](repeating: 0.3, count: 25), width: 5, height: 5,
            intrinsics: k, pose: pose)
        XCTAssertEqual(mesh.faces.count, 8)
        XCTAssertEqual(mesh.vertices.first?.z ?? 0, 2.7, accuracy: 0.00001)
        let a = mesh.vertices[0], b = mesh.vertices[3], c = mesh.vertices[1]
        XCTAssertGreaterThan(simd_cross(b - a, c - a).z, 0, "Front faces must point toward the camera")
        var depth = [Float](repeating: 0.3, count: 25); depth[12] = .nan
        XCTAssertEqual(DepthSurfaceBuilder.mesh(depth: depth, width: 5, height: 5, intrinsics: k, pose: pose).faces.count, 2)
        for y in 0..<5 { for x in 3..<5 { depth[y * 5 + x] = 0.5 } }
        let edges = DepthSurfaceBuilder.mesh(depth: depth, width: 5, height: 5, intrinsics: k, pose: matrix_identity_float4x4)
        for face in edges.faces {
            let z = [face.x,face.y,face.z].map { edges.vertices[Int($0)].z }
            XCTAssertLessThan((z.max() ?? 0) - (z.min() ?? 0), 0.01)
        }
        XCTAssertTrue(DepthSurfaceBuilder.mesh(depth: [Float](repeating: 1, count: 25), width: 5, height: 5,
            intrinsics: k, pose: pose).faces.isEmpty)
    }

    func testTrueDepthSurfaceFusionDoesNotStackRepeatedViews() {
        let fusion = DepthSurfaceFusion()
        let mesh = MeshChunk(vertices: [SIMD3<Float>(0,0,-0.3),SIMD3(0.01,0,-0.3),SIMD3(0,0.01,-0.3)], faces: [SIMD3(0,1,2)])
        let first = fusion.integrate(mesh, camera: .zero)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(fusion.integrate(mesh, camera: .zero).isEmpty)
        let back = MeshChunk(vertices: mesh.vertices, faces: [SIMD3(0,2,1)])
        XCTAssertEqual(fusion.integrate(back, camera: SIMD3(0,0,-0.6)).count, 1, "Opposite sides must be retained")
    }

    func testTrueDepthValidMaskTexturesAndRejectsCloseOccluders() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mesh = MeshChunk(vertices: [SIMD3<Float>(-0.01,-0.01,-0.3),SIMD3(0.01,-0.01,-0.3),SIMD3(0,0.01,-0.3)], faces: [SIMD3(0,1,2)])
        let camera = CameraSample(image: "image.jpg", depth: "depth.bin", confidence: "mask.bin", timestamp: 0,
            width: 100, height: 100, depthWidth: 10, depthHeight: 10,
            intrinsics: [100,0,0,0,100,0,50,50,1], cameraToWorld: flatten(matrix_identity_float4x4), tracking: "normal",
            depthSource: "trueDepth", confidenceSource: "validDepthMask")
        try Data(repeating: 1, count: 100).write(to: directory.appendingPathComponent("mask.bin"))
        for measured: Float in [0.3, 0.28] {
            var depth = Data(); for _ in 0..<100 { depth.appendFloat(measured) }
            try depth.write(to: directory.appendingPathComponent("depth.bin"))
            XCTAssertEqual(try ScanProcessor.writeOBJ(mesh: [mesh], frames: [camera], directory: directory), measured == 0.3 ? 1 : 0)
        }
    }

    func testInterruptedTrueDepthCaptureRetainsFineVoxels() throws {
        let id = UUID(), directory = ScanStore.root.appendingPathComponent(id.uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = try CaptureCheckpoint(id: id, mode: .closeUp, quality: .detail, directory: directory)
        let cloud = try PointCloudStore(directory: directory.appendingPathComponent("checkpoint/points"), voxelSize: CaptureMode.closeUp.voxelSize(.detail))
        for x: Float in [0.001,0.003] { try cloud.integrate(position: SIMD3(x,0,-0.3), color: SIMD3(10,20,30)) }
        try cloud.flush(releaseCache: true)
        try checkpoint.finish(duration: 5)
        let candidate = try XCTUnwrap(ScanRecovery.candidates().first { $0.id == id })
        let record = try ScanRecovery.recover(candidate) { _, _ in }
        XCTAssertEqual(record.mode, .closeUp)
        XCTAssertEqual(record.pointCount, 2)
        let readme = try String(contentsOf: directory.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("0.0015 m"))
        XCTAssertTrue(readme.contains("validDepthMask"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
