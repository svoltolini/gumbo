import Foundation

/// The caller holds one protected SMB read handle for this whole operation. Metadata is not a
/// resume validator: every retained byte is compared with that handle before the tail is appended.
nonisolated enum VerifiedSMBTransfer {
    struct Result: Sendable { let bytes: Int64; let verifiedPrefixBytes: Int64 }

    static func copy(size: Int64, maximumChunk: Int, destination: URL,
                     checkCancellation: () throws -> Void,
                     read: (Range<Int64>) throws -> Data,
                     progress: (Double) -> Void) throws -> Result {
        guard size > 0, maximumChunk > 0, maximumChunk <= 1024 * 1024 else { throw SMBDriveError.invalidResponse }
        try checkCancellation()
        let file = try CheckpointFileIO.payload(destination)
        defer { try? file.close() }
        let localSize = try file.seekToEnd()
        guard localSize <= UInt64(Int64.max) else { throw SMBDriveError.invalidResponse }
        var retained = Int64(localSize)
        if retained > size { try file.truncate(atOffset: 0); retained = 0 }
        var offset: Int64 = 0
        var verified: Int64 = 0
        while offset < size {
            try checkCancellation()
            let upper = offset + min(Int64(maximumChunk), size - offset)
            let bytes = try read(offset..<upper)
            guard !bytes.isEmpty, Int64(bytes.count) <= upper - offset else { throw SMBDriveError.invalidResponse }
            try checkCancellation()
            let priorCount = Int(min(Int64(bytes.count), max(0, retained - offset)))
            if priorCount > 0 {
                try file.seek(toOffset: UInt64(offset))
                let prior = try file.read(upToCount: priorCount) ?? Data()
                if prior.count == priorCount && prior == bytes.prefix(priorCount) {
                    verified += Int64(priorCount)
                } else {
                    // Keep only the prefix proved against this open; overwrite the changed suffix.
                    try file.truncate(atOffset: UInt64(offset))
                    retained = offset
                }
            }
            let skip = Int(min(Int64(bytes.count), max(0, retained - offset)))
            if skip < bytes.count {
                try file.seek(toOffset: UInt64(offset + Int64(skip)))
                try file.write(contentsOf: bytes.dropFirst(skip))
                // A crash can leave a shorter prefix; the next run verifies exactly what survived.
                try file.synchronize()
            }
            offset += Int64(bytes.count)
            progress(Double(offset) / Double(size))
        }
        try checkCancellation()
        try file.synchronize()
        return Result(bytes: size, verifiedPrefixBytes: verified)
    }
}
