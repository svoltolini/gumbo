import Foundation

public nonisolated enum MusicFileCondition: String, Sendable {
    case readable, damaged, unsupported, unavailable, changing
}

/// An inspection is tied to a source and an observed file version, never merely to its title.
public nonisolated struct MusicFileInspection: Identifiable, Sendable {
    public let track: Track
    public let sourceID: String
    public let condition: MusicFileCondition
    public let explanation: String
    public let size: Int64?
    public let modified: Date?
    public let version: String?
    /// Only an actual inspection may attach the provider's deletion witness.
    var reviewedEntry: RemoteEntry?
    public init(track: Track, sourceID: String, condition: MusicFileCondition, explanation: String,
                size: Int64?, modified: Date?, version: String? = nil) {
        self.track = track; self.sourceID = sourceID; self.condition = condition
        self.explanation = explanation; self.size = size; self.modified = modified; self.version = version
    }
    public var id: String { track.id }
    public var canDelete: Bool { condition == .damaged && size != nil && modified != nil && reviewedEntry != nil }
}

public nonisolated struct MusicFileDeletionReport: Sendable {
    public var deleted: [Track] = []
    public var failures: [MetadataWriteFailure] = []
    public var wasCancelled = false
    public var persistenceError: String?
    public init() {}
}

/// Conservative structural checks. A failed request or unfamiliar codec is never proof of damage.
public nonisolated enum MusicFileInspector {
    /// Hidden "._" companions left in an older catalogue never have a duration, but they are not
    /// songs, let alone damaged ones; the next library update removes them instead.
    public static func needsInspection(_ track: Track) -> Bool {
        track.path != nil && !track.isHiddenFile && (track.duration <= 0 || (!track.isEnriched && (track.enrichAttempts ?? 0) >= 3))
    }

    @concurrent public static func inspect(_ track: Track, drive: any RemoteFileDrive, now: Date = .now) async -> MusicFileInspection {
        if let deletionDrive = drive as? any RemoteDeletionDrive,
           drive.capabilities.contains(.delete), let path = track.path {
            do {
                let snapshot = try await deletionDrive.inspectionSnapshot(path)
                let reader = InspectionSnapshotDrive(id: drive.id, displayName: drive.displayName, snapshot: snapshot)
                var finding = await inspectContents(track, drive: reader, now: now)
                await snapshot.close()
                if finding.condition == .damaged { finding.reviewedEntry = snapshot.entry }
                return finding
            } catch is CancellationError {
                return MusicFileInspection(track: track, sourceID: drive.id, condition: .unavailable,
                    explanation: "The file check was stopped.", size: nil, modified: nil)
            } catch {
                // Read-only accounts can still inspect, but cannot obtain a deletion witness.
            }
        }
        return await inspectContents(track, drive: drive, now: now)
    }

    @concurrent private static func inspectContents(_ track: Track, drive: any RemoteFileDrive, now: Date) async -> MusicFileInspection {
        var observed: RemoteEntry?
        func result(_ condition: MusicFileCondition, _ explanation: String) -> MusicFileInspection {
            MusicFileInspection(track: track, sourceID: drive.id, condition: condition,
                                explanation: explanation, size: observed?.size, modified: observed?.modified, version: observed?.version)
        }
        do {
            try Task.checkCancellation()
            guard let path = track.path else { return result(.unavailable, "This song has no file on the server.") }
            let entry = try await drive.info(path)
            observed = entry
            guard !entry.isDirectory, let size = entry.size, size >= 0 else {
                return result(.unavailable, "The server could not provide the file's details.")
            }
            guard let modified = entry.modified, now.timeIntervalSince(modified) >= 3600 else {
                return result(.changing, "This file may still be downloading or converting. Try again after an hour.")
            }
            let finding: (MusicFileCondition, String)
            if size == 0 {
                finding = (.damaged, "The file is empty; it contains no audio.")
            } else if ["m4a", "mp4", "alac", "aac"].contains(entry.fileExtension) {
                finding = try await inspectMP4(path, size: size, drive: drive)
            } else {
                finding = (.unsupported, "This format needs a separate audio check. A playback error does not prove the file is damaged.")
            }
            let current = try await drive.info(path)
            guard current.sameVersion(as: entry) else {
                return result(.changing, "The file changed during the check. Let the download or conversion finish.")
            }
            return result(finding.0, finding.1)
        } catch {
            if (error as? RemoteWriteError) == .changed || (error as? ProviderError) == .changed {
                return result(.changing, "The file changed during the check. Let the download or conversion finish.")
            }
            return result(.unavailable, "Could not finish checking this file. " + MetadataWriter.message(for: error))
        }
    }

    private static func inspectMP4(_ path: String, size: Int64, drive: any RemoteFileDrive) async throws -> (MusicFileCondition, String) {
        func read(_ range: Range<Int64>) async throws -> Data {
            let bounded = min(size, range.lowerBound)..<min(size, range.upperBound)
            guard !bounded.isEmpty else { return Data() }
            let data = try await drive.read(path, range: bounded)
            guard Int64(data.count) == bounded.upperBound - bounded.lowerBound else { throw RemoteWriteError.incompleteTransfer }
            return data
        }
        let first = [UInt8](try await read(0..<min(size, 16)))
        guard first.count >= 12, MP4Tags.fourCC(first, 4) == "ftyp" else {
            return (.unsupported, "The file is not a recognised MP4 audio container. It may use a different format.")
        }
        var offset: Int64 = 0
        var hasAudio = false
        for _ in 0..<512 {
            try Task.checkCancellation()
            if offset == size {
                return hasAudio
                    ? (.damaged, "The audio data has no playback index. This can happen when a conversion is interrupted.")
                    : (.unsupported, "No audio structure was recognised. Check this file with its original music software.")
            }
            let header = [UInt8](try await read(offset..<(offset + min(16, size - offset))))
            guard header.count >= 8 else { return (.damaged, "The MP4 file ends inside a block header.") }
            var length = Int64(MP4Tags.u32(header, 0))
            var headerLength: Int64 = 8
            if length == 1 {
                guard header.count >= 16, let extended = Int64(exactly: MP4Tags.u64(header, 8)) else {
                    return (.damaged, "The MP4 file has an invalid block length.")
                }
                length = extended
                headerLength = 16
            } else if length == 0 { length = size - offset }
            guard length >= headerLength, length <= size - offset else {
                return (.damaged, "The MP4 file ends before its declared audio blocks are complete.")
            }
            let type = MP4Tags.fourCC(header, 4)
            if type == "moov" {
                if let media = try await MP4Tags.read(read: read), let duration = media.duration,
                   duration.isFinite, duration > 0, media.codec != nil {
                    return (.readable, "The audio index is readable. Try refreshing song information or checking your connection.")
                }
                return (.unsupported, "The playback index exists, but Gumbo cannot verify this format. Keep the file for a separate check.")
            }
            if type == "mdat" { hasAudio = true }
            offset += length
        }
        return (.unsupported, "This file has an unusually complex structure. Keep it for a separate check.")
    }

    /// Reclassifies the reviewed representation, then lets the provider enforce its deletion
    /// condition. SMB keeps a protected handle; the legacy DSM adapter retains its documented limits.
    public static func deleteReviewed(_ finding: MusicFileInspection, drive: any RemoteDeletionDrive,
                                      authorized: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard drive.capabilities.contains(.delete) else { throw RemoteWriteError.unsupported }
        guard finding.canDelete, finding.sourceID == drive.id, let reviewed = finding.reviewedEntry else {
            throw RemoteWriteError.changed
        }
        try Task.checkCancellation()
        guard await authorized() else { throw MetadataWriteError.notAuthorized }
        let current = await inspect(finding.track, drive: drive)
        guard current.canDelete, current.size == finding.size, current.modified == finding.modified,
              current.version == finding.version, current.reviewedEntry == reviewed else {
            throw RemoteWriteError.changed
        }
        try Task.checkCancellation()
        guard await authorized() else { throw MetadataWriteError.notAuthorized }
        guard drive.capabilities.contains(.delete) else { throw RemoteWriteError.unsupported }
        // A Stop after submission must not discard an acknowledgement for a real NAS deletion.
        // Recheck authorization inside the independent operation before it starts.
        try await Task {
            guard await authorized() else { throw MetadataWriteError.notAuthorized }
            guard drive.capabilities.contains(.delete) else { throw RemoteWriteError.unsupported }
            try await drive.deleteReviewed(reviewed, authorized: authorized)
        }.value
    }
}
