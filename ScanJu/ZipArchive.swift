import Foundation
import zlib

// Streaming ZIP (stored entries). Keeps original JPEGs and large PLY files out of RAM.
enum ZipArchive {
    static func crc32(_ data: Data, seed: UInt32 = 0xffffffff) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(zlib.crc32(uLong(seed ^ 0xffffffff), bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))) ^ 0xffffffff
        }
    }

    static func create(at output: URL, root: URL, files: [String], alignment: Int = 1, allowZIP64: Bool = true,
                       progress: (Double) -> Void = { _ in }) throws {
        let temporary = output.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        var central = Data()
        var offset: UInt64 = 0
        var usesZIP64 = false
        let totalBytes = try files.reduce(Int64(0)) { $0 + Int64(try root.appendingPathComponent($1).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } * 2
        var processedBytes: Int64 = 0
        var reported = -1.0
        func advanced(_ count: Int) {
            processedBytes += Int64(count)
            let fraction = min(1, Double(processedBytes) / Double(max(1, totalBytes)))
            if fraction - reported >= 0.005 { reported = fraction; progress(fraction) }
        }
        guard allowZIP64 || files.count < 65535 else { throw ScanFailure.message("Too many files for USDZ. The complete ZIP and source files are retained.") }
        for name in files {
            let url = root.appendingPathComponent(name)
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let largeSize = size >= Int(UInt32.max), largeOffset = offset >= UInt32.max
            guard allowZIP64 || (!largeSize && !largeOffset) else {
                throw ScanFailure.message("This scan exceeds the USDZ format limit. Use the complete ZIP or individual files.")
            }
            usesZIP64 = usesZIP64 || largeSize || largeOffset
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var crc: UInt32 = 0xffffffff
            // Foundation's file reads can return autoreleased NSData. Drain each
            // chunk, rather than retaining gigabytes until the whole job returns.
            while try autoreleasepool(invoking: {
                guard let chunk = try input.read(upToCount: 131072), !chunk.isEmpty else { return false }
                crc = crc32(chunk, seed: crc); advanced(chunk.count)
                return true
            }) {}
            crc ^= 0xffffffff
            try input.seek(toOffset: 0)
            let filename = Data(name.utf8)
            var extra = Data()
            if largeSize {
                extra.appendLE(UInt16(1)); extra.appendLE(UInt16(16))
                extra.appendLE(UInt64(size)); extra.appendLE(UInt64(size))
            }
            if alignment > 1 {
                var padding = (alignment - Int((offset + UInt64(30 + filename.count + extra.count)) % UInt64(alignment))) % alignment
                if padding > 0 {
                    if padding < 4 { padding += alignment }
                    extra.appendLE(UInt16(0x1986)); extra.appendLE(UInt16(padding - 4))
                    extra.append(Data(repeating: 0, count: padding - 4))
                }
            }
            var local = Data()
            local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(largeSize ? 45 : 20))
            local.appendLE(UInt16(0x800)); local.appendLE(UInt16(0))
            local.appendLE(UInt16(0)); local.appendLE(UInt16(0x21))
            local.appendLE(crc); local.appendLE(largeSize ? UInt32.max : UInt32(size)); local.appendLE(largeSize ? UInt32.max : UInt32(size))
            local.appendLE(UInt16(filename.count)); local.appendLE(UInt16(extra.count)); local.append(filename); local.append(extra)
            try handle.write(contentsOf: local)
            do {
                while try autoreleasepool(invoking: {
                    guard let chunk = try input.read(upToCount: 131072), !chunk.isEmpty else { return false }
                    try handle.write(contentsOf: chunk); advanced(chunk.count)
                    return true
                }) {}
                try input.close()
            } catch { try? input.close(); throw error }
            var centralExtra = Data()
            if largeSize || largeOffset {
                centralExtra.appendLE(UInt16(1))
                centralExtra.appendLE(UInt16((largeSize ? 16 : 0) + (largeOffset ? 8 : 0)))
                if largeSize { centralExtra.appendLE(UInt64(size)); centralExtra.appendLE(UInt64(size)) }
                if largeOffset { centralExtra.appendLE(offset) }
            }
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(45)); central.appendLE(UInt16(largeSize || largeOffset ? 45 : 20))
            central.appendLE(UInt16(0x800)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x21)); central.appendLE(crc)
            central.appendLE(largeSize ? UInt32.max : UInt32(size)); central.appendLE(largeSize ? UInt32.max : UInt32(size))
            central.appendLE(UInt16(filename.count)); central.appendLE(UInt16(centralExtra.count)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0))
            central.appendLE(largeOffset ? UInt32.max : UInt32(offset)); central.append(filename); central.append(centralExtra)
            offset += UInt64(local.count + size)
        }
        usesZIP64 = usesZIP64 || offset + UInt64(central.count) >= UInt32.max || files.count >= 65535
        guard allowZIP64 || !usesZIP64 else { throw ScanFailure.message("Export exceeds the USDZ format limit. Source files are retained.") }
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: directoryEnd(entryCount: UInt64(files.count), size: UInt64(central.count), offset: offset, zip64: usesZIP64))
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: output) }
        progress(1)
    }

    static func directoryEnd(entryCount: UInt64, size: UInt64, offset: UInt64, zip64: Bool) -> Data {
        var end = Data()
        if zip64 {
            end.appendLE(UInt32(0x06064b50)); end.appendLE(UInt64(44))
            end.appendLE(UInt16(45)); end.appendLE(UInt16(45))
            end.appendLE(UInt32(0)); end.appendLE(UInt32(0))
            end.appendLE(entryCount); end.appendLE(entryCount)
            end.appendLE(size); end.appendLE(offset)
            end.appendLE(UInt32(0x07064b50)); end.appendLE(UInt32(0))
            end.appendLE(offset + size); end.appendLE(UInt32(1))
        }
        end.appendLE(UInt32(0x06054b50)); end.appendLE(UInt16(0)); end.appendLE(UInt16(0))
        end.appendLE(UInt16(clamping: entryCount)); end.appendLE(UInt16(clamping: entryCount))
        end.appendLE(UInt32(clamping: size)); end.appendLE(UInt32(clamping: offset)); end.appendLE(UInt16(0))
        return end
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    mutating func appendFloat(_ value: Float) { appendLE(value.bitPattern) }
}

enum ScanFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
