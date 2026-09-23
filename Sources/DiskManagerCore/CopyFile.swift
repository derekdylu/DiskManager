import Darwin
import Foundation

struct CopyFailure: LocalizedError {
    let path: String
    let code: Int32
    var errorDescription: String? {
        "Copy failed (\(String(cString: strerror(code)))): \(path)"
    }
}

struct CopiedFileMetadata {
    let flags: UInt32
}

private let renameBlockingFlags =
    UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND)

func fileFlags(atPath path: String) -> UInt32? {
    var info = Darwin.stat()
    guard Darwin.lstat(path, &info) == 0 else { return nil }
    return info.st_flags
}

/// Clears the BSD file flags that make rename/remove fail with EPERM, and returns the original flags so they can be restored afterwards.
@discardableResult
func clearRenameBlockingFlags(atPath path: String) throws -> UInt32? {
    var info = Darwin.stat()
    guard Darwin.lstat(path, &info) == 0 else {
        if errno == ENOENT { return nil }
        throw CopyFailure(path: path, code: errno)
    }
    let original = info.st_flags
    let cleared = original & ~renameBlockingFlags
    if cleared != original, Darwin.lchflags(path, cleared) != 0 {
        throw CopyFailure(path: path, code: errno)
    }
    return original
}

func restoreFileFlags(_ flags: UInt32?, atPath path: String) {
    guard let flags else { return }
    // Filesystems such as exFAT may not support BSD flags; once the data is safely written, do not treat this as a failed copy.
    _ = Darwin.lchflags(path, flags)
}

func removeCopyTemporaryItem(atPath path: String) {
    _ = try? clearRenameBlockingFlags(atPath: path)
    try? FileManager.default.removeItem(atPath: path)
}

private final class CopyCallbackBox {
    let onBytes: (Int64) -> Void
    let isCancelled: () -> Bool
    init(onBytes: @escaping (Int64) -> Void, isCancelled: @escaping () -> Bool) {
        self.onBytes = onBytes
        self.isCancelled = isCancelled
    }
}

private typealias RawCopyCallback = @convention(c) (
    Int32, Int32, copyfile_state_t?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Int32

private let rawCallback: RawCopyCallback = { what, stage, state, _, _, ctxPtr in
    guard let ctxPtr else { return COPYFILE_CONTINUE }
    let box = Unmanaged<CopyCallbackBox>.fromOpaque(ctxPtr).takeUnretainedValue()
    if box.isCancelled() { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
        var copied: off_t = 0
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
            box.onBytes(Int64(copied))
        }
    }
    return COPYFILE_CONTINUE
}

/// Copies a file with copyfile(3): preserves modification time, xattrs, and ACLs, and reports bytes copied along the way.
/// When the destination filesystem does not support the metadata (e.g. exFAT), automatically falls back to "data + timestamp" mode.
func copyFilePreservingMetadata(
    from source: String,
    to destination: String,
    onBytes: @escaping (Int64) -> Void,
    isCancelled: @escaping () -> Bool
) throws -> CopiedFileMetadata {
    let sourceFlags = fileFlags(atPath: source) ?? 0
    let box = CopyCallbackBox(onBytes: onBytes, isCancelled: isCancelled)
    let unmanaged = Unmanaged.passRetained(box)
    defer { unmanaged.release() }

    func attempt(_ flags: Int32) -> Int32 {
        guard let state = copyfile_state_alloc() else {
            errno = ENOMEM
            return -1
        }
        defer { copyfile_state_free(state) }
        _ = copyfile_state_set(
            state, UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(rawCallback, to: UnsafeRawPointer.self))
        _ = copyfile_state_set(
            state, UInt32(COPYFILE_STATE_STATUS_CTX),
            UnsafeRawPointer(unmanaged.toOpaque()))
        return copyfile(source, destination, state, copyfile_flags_t(flags))
    }

    var rc = attempt(COPYFILE_ALL)
    var savedErrno = errno
    if rc < 0, savedErrno != ECANCELED, !isCancelled() {
        removeCopyTemporaryItem(atPath: destination)
        // COPYFILE_STAT also copies BSD flags such as uchg/uappnd; it is not merely the "timestamp".
        // When the destination does not support full metadata, copy only the data first, then set mtime separately.
        rc = attempt(COPYFILE_DATA)
        savedErrno = errno
        if rc == 0,
           let modified = try? FileManager.default.attributesOfItem(atPath: source)[.modificationDate]
                as? Date {
            try? FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: destination)
        }
    }
    if isCancelled() {
        removeCopyTemporaryItem(atPath: destination)
        throw CancellationError()
    }
    if rc < 0 {
        removeCopyTemporaryItem(atPath: destination)
        throw CopyFailure(path: source, code: savedErrno)
    }
    // COPYFILE_ALL may have copied the source's uchg flag. It must be temporarily unlocked before the atomic rename;
    // once the file is at its final path, SyncEngine restores the source flags.
    do {
        _ = try clearRenameBlockingFlags(atPath: destination)
    } catch {
        removeCopyTemporaryItem(atPath: destination)
        throw error
    }
    return CopiedFileMetadata(flags: sourceFlags)
}
