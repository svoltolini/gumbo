import Foundation

/// The write half of a remote drive: enough to put a rewritten song back where it came from.
public nonisolated protocol WritableRemoteDrive: RemoteDrive {
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
    case recoveryNeeded(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This server doesn't let Gumbo change files."
        case .readOnly: "This account can only read the music folder, so its files can't be changed."
        case .missing: "The file is no longer on the server."
        case .changed: "The file changed on the server. Update your library and try again."
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
        return false
    }
}

/// The names a replacement uses beside the song while it happens. Both start with a dot and end in
/// an extension the scan never indexes, so a leftover is never mistaken for music.
public nonisolated enum RemoteFileNames {
    public static func temporary(for name: String) -> String { ".\(name).gumbo-upload" }
    public static func backup(for name: String) -> String { ".\(name).gumbo-backup" }
}

extension WritableRemoteDrive {
    /// Reads the file in ranged requests; drives with a streaming download replace this.
    public func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws {
        guard maxBytes >= 0 else { throw RemoteDriveError.tooLarge }
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let chunk: Int64 = 8 * 1024 * 1024
        var offset: Int64 = 0
        while offset < maxBytes {
            try Task.checkCancellation()
            let end = min(maxBytes, offset + chunk)
            let data = try await read(path, range: offset..<end)
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if Int64(data.count) < end - (offset - Int64(data.count)) { break }
        }
        try handle.synchronize()
        // A file longer than promised is not one to rewrite: the copy here would be cut short.
        if offset == maxBytes {
            let extra = try await read(path, range: maxBytes..<maxBytes + 1)
            if !extra.isEmpty { throw RemoteDriveError.tooLarge }
        }
    }

    /// Puts `file` in place of the song at `path`. The new copy goes up under a temporary name and
    /// is checked for size first; the original is only moved aside once the copy is complete, and
    /// restored if the swap fails. If restoration cannot be confirmed, report the backup path.
    /// `expectedSize` is the local
    /// file's size and `modified` the time to stamp on the new copy.
    public func replaceFile(at path: String, with file: URL, expectedSize: Int64, modified: Date?, expectedOriginal: RemoteEntry? = nil,
                            authorized: @escaping @MainActor @Sendable () -> Bool = { true }) async throws {
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
                guard !current.isDirectory, current.size == expectedOriginal.size,
                      current.modified == expectedOriginal.modified else { throw RemoteWriteError.changed }
            } catch {
                try? await delete(temporary)
                throw error
            }
        }
        do {
            try Task.checkCancellation()
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
                      moved.modified == expectedOriginal.modified else { throw RemoteWriteError.changed }
            }
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
