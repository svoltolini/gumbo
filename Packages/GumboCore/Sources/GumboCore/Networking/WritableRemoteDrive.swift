import Foundation

/// The write half of a remote drive: enough to put a rewritten song back where it came from.
public nonisolated protocol WritableRemoteDrive: RemoteDeletionDrive {
    /// Size and modification time of one file; throws a missing-path error when it is gone.
    func info(_ path: String) async throws -> RemoteEntry
    /// Streams a whole file to disk, refusing anything longer than `maxBytes`.
    func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws
    /// Stores a local file as `folder/name`, replacing any file of that name, stamped with `modified` when given.
    func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws
    /// Renames the file at `path` within its folder.
    func rename(_ path: String, to name: String) async throws
    func delete(_ path: String) async throws
}

/// Why a write to the drive did not happen.
public nonisolated enum RemoteWriteError: LocalizedError, Sendable, Equatable {
    /// The server offers no way to change files from here.
    case unsupported
    case readOnly
    case missing
    /// The copy on the server does not have the size it should; nothing was replaced.
    case incompleteTransfer
    case changed
    case deletionUnconfirmed
    case helperDeletionUnconfirmed(UUID)
    case recoveryNeeded(String)

    public var isDeletionUnconfirmed: Bool {
        switch self {
        case .deletionUnconfirmed, .helperDeletionUnconfirmed: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This server doesn't let Gumbo change files."
        case .readOnly: "This account can only read the music folder, so its files can't be changed."
        case .missing: "The file is no longer on the server."
        case .changed: "The file changed on the server. Update your library and try again."
        case .helperDeletionUnconfirmed(let jobID): "The helper could not confirm deletion. Work has stopped. Check job \(jobID.uuidString.lowercased()) in the helper before deleting this file again."
        case .deletionUnconfirmed: "The server may have deleted this song, but its reply was lost. Deletion has stopped. Refresh your library before reviewing any more files."
        case .recoveryNeeded(let path): "The replacement could not be confirmed. Check the original file and its backup at \(path) in File Station before trying again."
        case .incompleteTransfer: "The file didn't transfer completely, so it was left unchanged."
        }
    }
}

nonisolated extension Error {
    /// True when the server refused to change a file: a read-only account, share or file system.
    public var isWriteDenied: Bool {
        if let synology = self as? SynologyError, case .api(let code, _) = synology {
            return [105, 403, 404, 405, 407, 411].contains(code)
        }
        if let write = self as? RemoteWriteError { return write == .readOnly }
        if let smb = self as? SMBDriveError { return smb == .permissionDenied }
        return false
    }
}

/// The names a replacement uses beside the song while it happens. Both start with a dot and end in
/// an extension the scan never indexes, so a leftover is never mistaken for music.
public nonisolated enum RemoteFileNames {
    public static func temporary(for name: String) -> String { ".\(name).gumbo-upload" }
    public static func backup(for name: String) -> String { ".\(name).gumbo-backup" }
}

extension RemoteFileDrive {
    /// Reads the file in ranged requests; drives with a streaming download replace this.
    @concurrent public nonisolated func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws {
        guard maxBytes >= 0 else { throw RemoteDriveError.tooLarge }
        try Task.checkCancellation()
        let before = try await info(path)
        guard !before.isDirectory, let size = before.size, size >= 0 else { throw RemoteWriteError.incompleteTransfer }
        guard size <= maxBytes else { throw RemoteDriveError.tooLarge }
        let temporary = destination.deletingLastPathComponent().appending(path: ".gumbo-download-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let end = offset + min(1024 * 1024, size - offset)
            let data = try await read(path, range: offset..<end, matching: before)
            guard !data.isEmpty, Int64(data.count) <= end - offset else { throw RemoteWriteError.incompleteTransfer }
            try Task.checkCancellation()
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            // Short reads need another range; they are not proof of EOF.
        }
        try handle.synchronize()
        try Task.checkCancellation()
        let after = try await info(path)
        guard after.sameVersion(as: before) else { throw RemoteWriteError.changed }
        // Verify the reported length too; a lying or stale listing must not produce a truncated file.
        if size < Int64.max, !(try await read(path, range: size..<(size + 1), matching: before)).isEmpty { throw RemoteDriveError.tooLarge }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

}

extension WritableRemoteDrive {
    /// Puts `file` in place of the song at `path`. The new copy goes up under a temporary name and
    /// is checked for size first; the original is only moved aside once the copy is complete, and
    /// restored if the swap fails. If restoration cannot be confirmed, report the backup path.
    /// `expectedSize` is the local
    /// file's size and `modified` the time to stamp on the new copy.
    public func replaceFile(at path: String, with file: URL, expectedSize: Int64, modified: Date?, expectedOriginal: RemoteEntry? = nil,
                            authorized: @escaping @MainActor @Sendable () -> Bool = { true }) async throws {
        guard capabilities.supportsTagReplacement else { throw RemoteWriteError.unsupported }
        try Task.checkCancellation()
        guard authorized() else { throw MetadataWriteError.notAuthorized }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !folder.isEmpty, !name.isEmpty else { throw RemoteWriteError.missing }
        let transaction = UUID().uuidString
        let temporaryName = RemoteFileNames.temporary(for: name) + "-" + transaction
        let backupName = RemoteFileNames.backup(for: name) + "-" + transaction
        let temporary = folder + "/" + temporaryName
        let backup = folder + "/" + backupName
        do {
            try await upload(file, toFolder: folder, name: temporaryName, modified: modified)
        } catch {
            // A transfer that broke off may have left part of the copy behind.
            try? await delete(temporary)
            throw error
        }
        let uploaded: RemoteEntry
        do {
            uploaded = try await info(temporary)
        } catch {
            try? await delete(temporary)
            throw error
        }
        guard uploaded.size == expectedSize else {
            try? await delete(temporary)
            throw RemoteWriteError.incompleteTransfer
        }
        // Another person or converter may have changed the file while this copy was prepared.
        // Unique staging names also keep simultaneous clients from swapping each other's uploads.
        if let expectedOriginal {
            do {
                let current = try await info(path)
                guard !current.isDirectory, current.sameVersion(as: expectedOriginal) else { throw RemoteWriteError.changed }
            } catch {
                try? await delete(temporary)
                throw error
            }
        }
        do {
            try Task.checkCancellation()
            guard capabilities.supportsTagReplacement else { throw RemoteWriteError.unsupported }
            guard authorized() else { throw MetadataWriteError.notAuthorized }
        } catch {
            try? await delete(temporary)
            throw error
        }
        do {
            try await rename(path, to: backupName)
        } catch let originalError {
            // A lost response may mean the rename happened, even though the request threw.
            // Restore our unique backup if it exists; never assume the original stayed put.
            do {
                _ = try await info(backup)
                try await rename(backup, to: name)
            } catch {
                try? await delete(temporary)
                if error.isMissingPath || (error as? RemoteWriteError) == .missing { throw originalError }
                throw RemoteWriteError.recoveryNeeded(backup)
            }
            try? await delete(temporary)
            throw originalError
        }
        do {
            // Two clients can both pass the first check before either renames. Check the file
            // actually moved aside as well, before replacing it or discarding its backup.
            if let expectedOriginal {
                let moved = try await info(backup)
                guard !moved.isDirectory, moved.size == expectedOriginal.size,
                      moved.modified == expectedOriginal.modified, moved.version == expectedOriginal.version else { throw RemoteWriteError.changed }
            }
            guard capabilities.supportsTagReplacement else { throw RemoteWriteError.unsupported }
            guard authorized() else { throw MetadataWriteError.notAuthorized }
            try await rename(temporary, to: name)
        } catch {
            do { try await rename(backup, to: name) }
            catch {
                try? await delete(temporary)
                throw RemoteWriteError.recoveryNeeded(backup)
            }
            try? await delete(temporary)
            throw error
        }
        do {
            try await delete(backup)
        } catch {
            diagnostics("The previous copy \(backup) could not be removed: \(error.localizedDescription)")
        }
    }
}
