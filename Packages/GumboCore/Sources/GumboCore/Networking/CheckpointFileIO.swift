import Foundation
import Darwin

/// Local cache data is untrusted after a crash or restore. Inspect the opened descriptor rather
/// than following an unchecked link, and never modify an inode shared with another local path.
nonisolated enum CheckpointFileIO {
    static func payload(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SMBDriveError.invalidPath }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_nlink == 1 else { close(fd); throw SMBDriveError.invalidPath }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func descriptor(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var details = stat()
        let limit = 16 * 1024
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_nlink == 1, details.st_size > 0, details.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    static func size(_ url: URL) -> Int64? {
        var details = stat()
        guard lstat(url.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_nlink == 1, details.st_size >= 0 else { return nil }
        return details.st_size
    }
}
