#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import CryptoKit
import CGumboSMB
import Darwin

/// A context and its C file handles never cross this serial queue. Network calls have a deadline;
/// task cancellation stops before the next chunk without destroying an in-use C context.
nonisolated final class SMBCSession: SMBReadSession, @unchecked Sendable {
    private let queue = DispatchQueue(label: "one.gumbo.smb.read", qos: .userInitiated)
    private let settings: SMBConnectionSettings
    private let password: String
    private var context: OpaquePointer?
    private var deletionHandle: OpaquePointer?
    var supportsReviewedDeletion: Bool { true }

    init(settings: SMBConnectionSettings, password: String) {
        self.settings = settings
        self.password = password
    }

    deinit {
        // Pending queue closures retain self. By deinit there is no operation using the context.
        if let context { smb2_destroy_context(context) }
    }

    func connect() async throws {
        try await perform { client, cancellation in
            try client.ensureConnected(cancellation)
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeContext()
                continuation.resume()
            }
        }
    }

    func list(_ path: String) async throws -> [SMBFileInfo] {
        try await perform { client, cancellation in
            let context = try client.connected(cancellation)
            guard let directory = smb2_opendir(context, path) else { throw client.failure() }
            defer { smb2_closedir(context, directory) }
            var result: [SMBFileInfo] = []
            while let entry = smb2_readdir(context, directory) {
                try cancellation.check()
                guard result.count < 100_000, let name = entry.pointee.name else { throw SMBDriveError.invalidResponse }
                result.append(try Self.fileInfo(entry.pointee.st, name: String(cString: name)))
            }
            return result
        }
    }

    func info(_ path: String) async throws -> SMBFileInfo {
        try await perform { client, cancellation in
            let context = try client.connected(cancellation)
            var stat = smb2_stat_64()
            try client.check(smb2_stat(context, path, &stat))
            return try Self.fileInfo(stat, name: (path as NSString).lastPathComponent)
        }
    }

    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        try await perform { client, cancellation in
            let context = try client.connected(cancellation)
            var stat = smb2_stat_64()
            try client.check(smb2_stat(context, path, &stat))
            guard stat.smb2_type == SMB2_TYPE_FILE else { throw SMBDriveError.invalidPath }
            guard let file = smb2_open(context, path, O_RDONLY) else { throw client.failure() }
            defer { _ = smb2_close(context, file) }
            let maximum = min(Int64(smb2_get_max_read_size(context)), 1024 * 1024)
            guard maximum > 0 else { throw SMBDriveError.invalidResponse }
            var result = Data()
            var offset = range.lowerBound
            while offset < range.upperBound {
                try cancellation.check()
                let count = Int(min(maximum, range.upperBound - offset))
                var bytes = [UInt8](repeating: 0, count: count)
                let read = smb2_pread(context, file, &bytes, UInt32(count), UInt64(offset))
                try client.check(read)
                guard read <= count else { throw SMBDriveError.invalidResponse }
                if read == 0 { break }
                result.append(contentsOf: bytes.prefix(Int(read)))
                offset += Int64(read)
            }
            try cancellation.check()
            return result
        }
    }

    func copyVerified(_ path: String, to destination: URL, expectedBytes: Int64?,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        // The protected handle spans the whole file. Give it its own authenticated context so
        // playback/seek, artwork and listing requests can still use the ordinary session queue.
        let transfer = SMBCSession(settings: settings, password: password)
        return try await transfer.perform { client, cancellation in
            let context = try client.connected(cancellation)
            guard let file = gumbo_smb2_open_read_snapshot(context, path) else { throw client.failure() }
            defer { _ = smb2_close(context, file) }
            var before = smb2_stat_64()
            try client.check(smb2_fstat(context, file, &before))
            guard before.smb2_type == SMB2_TYPE_FILE,
                  before.smb2_attributes & UInt32(SMB2_FILE_ATTRIBUTE_REPARSE_POINT) == 0,
                  before.smb2_size > 0, before.smb2_size <= UInt64(Int64.max),
                  expectedBytes == nil || expectedBytes == Int64(before.smb2_size) else { throw ProviderError.changed }
            let maximum = min(smb2_get_max_read_size(context), 1024 * 1024)
            let copied = try VerifiedSMBTransfer.copy(size: Int64(before.smb2_size), maximumChunk: Int(maximum),
                                                      destination: destination, checkCancellation: cancellation.check) { range in
                var bytes = [UInt8](repeating: 0, count: range.count)
                let count = smb2_pread(context, file, &bytes, UInt32(bytes.count), UInt64(range.lowerBound))
                try client.check(count)
                guard count >= 0, count <= bytes.count else { throw SMBDriveError.invalidResponse }
                return Data(bytes.prefix(Int(count)))
            } progress: { fraction in progress(fraction) }
            try cancellation.check()
            var after = smb2_stat_64()
            try client.check(smb2_fstat(context, file, &after))
            // Detect observed out-of-protocol/local writers too. These attributes are never a
            // strong persisted validator; the protected handle plus byte verification does that.
            guard before.smb2_type == after.smb2_type, before.smb2_ino == after.smb2_ino,
                  before.smb2_size == after.smb2_size, before.smb2_mtime == after.smb2_mtime,
                  before.smb2_mtime_nsec == after.smb2_mtime_nsec, before.smb2_ctime == after.smb2_ctime,
                  before.smb2_ctime_nsec == after.smb2_ctime_nsec, before.smb2_btime == after.smb2_btime,
                  before.smb2_btime_nsec == after.smb2_btime_nsec else {
                try? FileManager.default.removeItem(at: destination)
                throw ProviderError.changed
            }
            return copied.bytes
        }
    }

    func reviewDeletion(_ path: String) async throws -> RemoteEntry {
        let transaction = SMBCSession(settings: settings, password: password)
        do {
            let entry = try await transaction.openDeletion(path)
            await transaction.disconnect()
            return entry
        } catch {
            await transaction.disconnect()
            throw error
        }
    }

    func deleteReviewed(_ entry: RemoteEntry, authorized: @escaping @MainActor @Sendable () -> Bool) async throws {
        let transaction = SMBCSession(settings: settings, password: password)
        do {
            let path = try SMBConnectionSettings.relativePath(entry.path)
            let current = try await transaction.openDeletion(path)
            guard current == entry else { throw RemoteWriteError.changed }
            try Task.checkCancellation()
            guard await authorized() else { throw CancellationError() }
            // Keep the verified handle locked while authority is checked. Once dispatched, wait
            // for the mutation's acknowledgement even if the caller cancels. Never reconnect/replay.
            try await transaction.commitDeletion()
            await transaction.disconnect()
        } catch {
            await transaction.disconnect()
            throw error
        }
    }

    private func openDeletion(_ path: String) async throws -> RemoteEntry {
        try await perform { client, cancellation in
            let context = try client.connected(cancellation)
            guard client.deletionHandle == nil,
                  let file = gumbo_smb2_open_delete_snapshot(context, path) else { throw client.failure() }
            client.deletionHandle = file
            var before = smb2_stat_64()
            try client.check(smb2_fstat(context, file, &before))
            guard before.smb2_type == SMB2_TYPE_FILE,
                  before.smb2_attributes & UInt32(SMB2_FILE_ATTRIBUTE_REPARSE_POINT) == 0,
                  before.smb2_size <= UInt64(Int64.max) else { throw SMBDriveError.invalidPath }
            let maximum = min(smb2_get_max_read_size(context), 1024 * 1024)
            guard maximum > 0 else { throw SMBDriveError.invalidResponse }
            // Size/mtime alone can miss converters preserving timestamps. Review every byte,
            // under one server handle which denies SMB writes, rename and deletion.
            var hash = SHA256()
            var offset: UInt64 = 0
            let deadline = ContinuousClock.now + .seconds(120)
            while offset < before.smb2_size {
                try cancellation.check()
                guard ContinuousClock.now < deadline else { throw SMBDriveError.timedOut }
                let count = UInt32(min(UInt64(maximum), before.smb2_size - offset))
                var bytes = [UInt8](repeating: 0, count: Int(count))
                let read = smb2_pread(context, file, &bytes, count, offset)
                try client.check(read)
                guard read > 0, read <= count else { throw SMBDriveError.invalidResponse }
                hash.update(data: Data(bytes.prefix(Int(read))))
                offset += UInt64(read)
            }
            var after = smb2_stat_64()
            try client.check(smb2_fstat(context, file, &after))
            let identity: @Sendable (smb2_stat_64) -> [UInt64] = { stat in
                [stat.smb2_ino, stat.smb2_size, stat.smb2_mtime, UInt64(stat.smb2_mtime_nsec),
                 stat.smb2_ctime, UInt64(stat.smb2_ctime_nsec), stat.smb2_btime, UInt64(stat.smb2_btime_nsec)]
            }
            guard before.smb2_type == after.smb2_type, before.smb2_attributes == after.smb2_attributes,
                  identity(before) == identity(after) else { throw RemoteWriteError.changed }
            let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let version = "smb-delete-v1:" + identity(before).map(String.init).joined(separator: ":") + ":" + fingerprint
            let info = try Self.fileInfo(before, name: (path as NSString).lastPathComponent)
            return RemoteEntry(path: "/" + path, name: info.name, isDirectory: false,
                               size: info.size, modified: info.modified, version: version)
        }
    }

    private func commitDeletion() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let context, let file = deletionHandle else {
                    continuation.resume(throwing: SMBDriveError.disconnected)
                    return
                }
                // No cancellation callback and no retry after the destructive request is sent.
                gumbo_smb2_set_cancellation(context, nil, nil)
                let marked = gumbo_smb2_mark_delete(context, file)
                deletionHandle = nil
                if marked < 0 {
                    closeContext()
                    continuation.resume(throwing: RemoteWriteError.deletionUnconfirmed)
                    return
                }
                let closed = smb2_close(context, file)
                if closed < 0 {
                    closeContext()
                    continuation.resume(throwing: RemoteWriteError.deletionUnconfirmed)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (SMBCSession, SMBOperationCancellation) throws -> T) async throws -> T {
        let cancellation = SMBOperationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    defer { if let context { gumbo_smb2_set_cancellation(context, nil, nil) } }
                    do {
                        try cancellation.check()
                        let result: T
                        do {
                            result = try operation(self, cancellation)
                        } catch let error as SMBDriveError where error.canReconnect {
                            closeContext()
                            try cancellation.check()
                            result = try operation(self, cancellation)
                        }
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        // A cancelled C directory enumeration may still own a server handle.
                        // The call has returned on this queue, so retiring its context is safe.
                        closeContext()
                        continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func connected(_ cancellation: SMBOperationCancellation) throws -> OpaquePointer {
        try ensureConnected(cancellation)
        guard let context else { throw SMBDriveError.disconnected }
        return context
    }

    private func ensureConnected(_ cancellation: SMBOperationCancellation) throws {
        try cancellation.check()
        if let context { installCancellation(cancellation, on: context); return }
        guard let next = smb2_init_context() else { throw SMBDriveError.disconnected }
        context = next
        installCancellation(cancellation, on: next)
        smb2_set_timeout(next, 10)
        smb2_set_authentication(next, Int32(SMB2_SEC_NTLMSSP.rawValue))
        smb2_set_user(next, settings.user)
        smb2_set_domain(next, settings.domain)
        smb2_set_password(next, password)
        gumbo_smb2_require_secure_session(next, settings.security == .encrypted ? 1 : 0)
        do {
            let status = smb2_connect_share(next, settings.server, settings.share, settings.user)
            if status < 0, let rejection = SMBDriveError.authenticationFailure(
                for: UInt32(bitPattern: smb2_get_nterror(next))
            ) { throw rejection }
            try check(status)
            let dialect = smb2_get_dialect(next)
            guard dialect >= 0x0202, settings.security != .encrypted || dialect >= 0x0300 else { throw SMBDriveError.securityPolicy }
            try cancellation.check()
        } catch {
            closeContext()
            throw error
        }
    }

    private func installCancellation(_ cancellation: SMBOperationCancellation, on context: OpaquePointer) {
        gumbo_smb2_set_cancellation(context, { value in
            guard let value else { return 1 }
            return Unmanaged<SMBOperationCancellation>.fromOpaque(value).takeUnretainedValue().isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
    }

    private func closeContext() {
        deletionHandle = nil
        if let context {
            // Destroy closes the socket and releases pending state without another network wait.
            smb2_destroy_context(context)
            self.context = nil
        }
    }

    private func check(_ status: Int32) throws {
        if status < 0 { throw failure(status) }
    }

    private func failure(_ status: Int32? = nil) -> SMBDriveError {
        // Never forward a server-provided message (which can contain paths or credentials) to UI/logs.
        let message = context.flatMap { smb2_get_error($0) }.map { String(cString: $0).lowercased() } ?? ""
        if ["signing", "signature", "encrypt", "guest", "anonymous", "required protection"].contains(where: message.contains) { return .securityPolicy }
        // Pointer-returning opens carry NTSTATUS, not a reliable thread-local errno.
        let serverStatus = context.map { UInt32(bitPattern: smb2_get_nterror($0)) } ?? 0
        let openError = serverStatus == 0 ? Int32(errno == 0 ? EIO : errno) : nterror_to_errno(serverStatus)
        let raw = status ?? -openError
        let code = raw == Int32.min ? EIO : abs(raw)
        switch code {
        case ENOENT: return .missingPath
        case EACCES, EPERM, EROFS: return .permissionDenied
        case EBUSY, ETXTBSY, EDEADLK: return .fileBusy
        case ETIMEDOUT: return .timedOut
        case ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ECONNREFUSED, ENETDOWN, ENETUNREACH, EHOSTUNREACH: return .disconnected
        default: return .io(code)
        }
    }

    private static func fileInfo(_ stat: smb2_stat_64, name: String) throws -> SMBFileInfo {
        guard stat.smb2_size <= UInt64(Int64.max) else { throw SMBDriveError.invalidResponse }
        let modified = stat.smb2_mtime == 0 ? nil : Date(timeIntervalSince1970: Double(stat.smb2_mtime) + Double(stat.smb2_mtime_nsec) / 1_000_000_000)
        return SMBFileInfo(name: name, isDirectory: stat.smb2_type == SMB2_TYPE_DIRECTORY,
                           isSymbolicLink: stat.smb2_type == SMB2_TYPE_LINK, size: Int64(stat.smb2_size), modified: modified)
    }
}

private nonisolated final class SMBOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

private nonisolated extension SMBDriveError {
    var canReconnect: Bool { self == .disconnected || self == .timedOut }
}
#endif
