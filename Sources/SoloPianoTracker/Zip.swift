import CZlib
import Foundation

/// Reads one named file out of a zip archive, which is what a compressed MusicXML (.mxl) file is.
///
/// Foundation has no zip reader, and an .mxl holds at most a handful of small entries, so this walks
/// the central directory and inflates the one entry asked for. Only the two methods a .mxl uses are
/// handled: stored, and deflate.
struct Zip {
    enum Failure: Error { case notAnArchive, noSuchFile, unsupportedMethod, corrupt }

    private struct Entry {
        let name: String
        let method: UInt16
        let compressed: Int
        let uncompressed: Int
        let offset: Int  // of the local file header
    }

    private let data: Data
    private let entries: [String: Entry]

    init(_ data: Data) throws {
        self.data = data
        // The central directory is found from its end record, which sits at the end of the file
        // behind a comment of unknown length, so it is searched for backwards.
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var end: Int?
        let bytes = [UInt8](data)
        if bytes.count >= 22 {
            for start in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
                if Array(bytes[start..<start + 4]) == signature { end = start; break }
            }
        }
        guard let end else { throw Failure.notAnArchive }
        let count = Int(Zip.short(bytes, end + 10))
        var offset = Int(Zip.long(bytes, end + 16))
        var found: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, Zip.long(bytes, offset) == 0x0201_4B50 else {
                throw Failure.corrupt
            }
            let nameLength = Int(Zip.short(bytes, offset + 28))
            let extraLength = Int(Zip.short(bytes, offset + 30))
            let commentLength = Int(Zip.short(bytes, offset + 32))
            // The name's length is the archive's own word for it, and a damaged file can claim a
            // name running off the end. Slicing on that claim does not throw, it traps, so the
            // whole entry is measured against the file before any of it is read.
            guard offset + 46 + nameLength + extraLength + commentLength <= bytes.count else {
                throw Failure.corrupt
            }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            found[name] = Entry(name: name,
                                method: Zip.short(bytes, offset + 10),
                                compressed: Int(Zip.long(bytes, offset + 20)),
                                uncompressed: Int(Zip.long(bytes, offset + 24)),
                                offset: Int(Zip.long(bytes, offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
        entries = found
    }

    var names: [String] { Array(entries.keys) }

    func file(named name: String) throws -> Data {
        guard let entry = entries[name] else { throw Failure.noSuchFile }
        let bytes = [UInt8](data)
        let header = entry.offset
        guard header + 30 <= bytes.count, Zip.long(bytes, header) == 0x0403_4B50 else { throw Failure.corrupt }
        let nameLength = Int(Zip.short(bytes, header + 26))
        let extraLength = Int(Zip.short(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressed <= bytes.count else { throw Failure.corrupt }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressed))
        switch entry.method {
        case 0: return payload
        case 8: return try Zip.inflate(payload, into: max(entry.uncompressed, 1))
        default: throw Failure.unsupportedMethod
        }
    }

    /// Raw deflate, which is what a zip entry holds.
    private static func inflate(_ payload: Data, into size: Int) throws -> Data {
        var out = Data(count: size)
        // zlib's inflate with a negative window: raw deflate, no zlib header, as a zip entry holds
        let written = out.withUnsafeMutableBytes { target -> Int in
            payload.withUnsafeBytes { source -> Int in
                var stream = z_stream()
                guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return 0 }
                defer { CZlib.inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(payload.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(size)
                let status = CZlib.inflate(&stream, Z_FINISH)
                return status == Z_STREAM_END || status == Z_OK || status == Z_BUF_ERROR ? Int(stream.total_out) : 0
            }
        }
        guard written > 0 else { throw Failure.corrupt }
        return out.prefix(written)
    }

    private static func short(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func long(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
