import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Computes on-disk allocated size of a file or directory tree.
///
/// We use allocated size (blocks actually occupied) rather than logical file
/// size, because that is what the user reclaims — and it matches what `du` and
/// `df` report. Symlinks are never followed (we measure the link, not its
/// target), which also keeps us from double-counting or wandering out of a tree.
///
/// The directory walk uses `getattrlistbulk(2)`, which returns the name, type,
/// and allocated size of *many* entries per syscall. That is dramatically faster
/// than `FileManager.enumerator` (one `stat` per file) on the large, deep trees
/// this app targets — npm/gradle caches, `node_modules`, DerivedData. If the fast
/// path is unavailable on a volume, we fall back to the FileManager walk.
public struct SizeCalculator: Sendable {

    public init() {}

    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
    ]

    /// Allocated size in bytes of a single file. Returns 0 for symlinks/directories.
    public func fileAllocatedSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Self.sizeKeys) else { return 0 }
        return Self.allocatedSize(from: values)
    }

    /// Extract the best available allocated size from already-fetched values, so
    /// callers that already have `resourceValues` don't fetch them a second time.
    private static func allocatedSize(from values: URLResourceValues) -> Int64 {
        if values.isSymbolicLink == true { return 0 }
        if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return Int64(allocated)
        }
        if let logical = values.fileSize { return Int64(logical) }
        return 0
    }

    /// Recursively sum the allocated size of everything under `url`. Does not
    /// follow symlinks. Errors on individual entries are ignored so a single
    /// unreadable file never aborts the whole measurement.
    public func directoryAllocatedSize(_ url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return 0 }
        if values?.isDirectory != true {
            return fileAllocatedSize(url)
        }

        #if canImport(Darwin)
        if let fast = Self.bulkDirectorySize(url.path, isCancelled: isCancelled) {
            return fast
        }
        #endif
        return slowDirectoryAllocatedSize(url, isCancelled: isCancelled)
    }

    // MARK: - FileManager fallback

    private func slowDirectoryAllocatedSize(_ url: URL, isCancelled: () -> Bool) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(Self.sizeKeys),
            options: [], // deliberately NOT skipping hidden files — caches contain dotfiles
            errorHandler: { _, _ in true } // keep going past unreadable entries
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            if isCancelled() { break }
            // One fetch, reused for both the type check and the size — no second
            // round-trip to the filesystem per file.
            guard let values = try? child.resourceValues(forKeys: Self.sizeKeys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Self.allocatedSize(from: values)
            }
        }
        return total
    }
}

#if canImport(Darwin)
// MARK: - getattrlistbulk fast path

extension SizeCalculator {

    // Attribute request bits (from <sys/attr.h>), declared here so the exact
    // buffer layout we parse is unambiguous.
    private static let attrBitMapCount: UInt16 = 5           // ATTR_BIT_MAP_COUNT
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000 // ATTR_CMN_RETURNED_ATTRS
    private static let cmnError: UInt32        = 0x2000_0000 // ATTR_CMN_ERROR
    private static let cmnName: UInt32         = 0x0000_0001 // ATTR_CMN_NAME
    private static let cmnObjType: UInt32      = 0x0000_0008 // ATTR_CMN_OBJTYPE
    private static let fileAllocSize: UInt32   = 0x0000_0004 // ATTR_FILE_ALLOCSIZE

    // fsobj_type_t values.
    private static let vreg: UInt32 = 1  // regular file
    private static let vdir: UInt32 = 2  // directory
    private static let vlnk: UInt32 = 5  // symlink

    /// Sum a directory tree using `getattrlistbulk`. Returns nil only if the
    /// mechanism is unavailable at the root (e.g. the volume returns ENOTSUP),
    /// signalling the caller to use the FileManager fallback instead.
    static func bulkDirectorySize(_ rootPath: String, isCancelled: () -> Bool) -> Int64? {
        let bufSize = 128 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        var attrList = attrlist()
        attrList.bitmapcount = attrBitMapCount
        attrList.commonattr = cmnReturnedAttrs | cmnError | cmnName | cmnObjType
        attrList.fileattr = fileAllocSize

        var unsupportedAtRoot = false
        let total = sumLevel(rootPath, attrList: &attrList, buf: buf, bufSize: bufSize,
                             isRoot: true, unsupportedAtRoot: &unsupportedAtRoot,
                             isCancelled: isCancelled)
        return unsupportedAtRoot ? nil : total
    }

    /// Sum one directory level, then recurse into its subdirectories. The buffer
    /// is reused across the whole walk — subdirectory names are copied out to
    /// Swift strings before we recurse, so nothing dangles.
    private static func sumLevel(_ path: String,
                                 attrList: inout attrlist,
                                 buf: UnsafeMutableRawPointer,
                                 bufSize: Int,
                                 isRoot: Bool,
                                 unsupportedAtRoot: inout Bool,
                                 isCancelled: () -> Bool) -> Int64 {
        let fd = open(path, O_RDONLY, 0)
        if fd < 0 { return 0 }             // unreadable dir → skip, like the slow path

        var total: Int64 = 0
        var subdirs: [String] = []
        var firstCall = true

        while true {
            if isCancelled() { break }
            let count = withUnsafeMutablePointer(to: &attrList) { alp in
                getattrlistbulk(fd, UnsafeMutableRawPointer(alp), buf, bufSize, 0)
            }
            if count == -1 {
                if firstCall && isRoot && errno == ENOTSUP { unsupportedAtRoot = true }
                break
            }
            firstCall = false
            if count == 0 { break }        // no more entries

            var entry = buf
            for _ in 0..<count {
                parseEntry(entry, total: &total, subdirs: &subdirs)
                // Each entry begins with its own total length; jump to the next.
                let length = entry.loadUnaligned(as: UInt32.self)
                entry = entry.advanced(by: Int(length))
            }
        }
        close(fd)

        for name in subdirs {
            if isCancelled() { break }
            total += sumLevel(path + "/" + name, attrList: &attrList, buf: buf, bufSize: bufSize,
                              isRoot: false, unsupportedAtRoot: &unsupportedAtRoot,
                              isCancelled: isCancelled)
        }
        return total
    }

    /// Parse a single packed `getattrlistbulk` entry: add regular-file allocated
    /// size to `total`, and collect subdirectory names for recursion. Fields are
    /// read at their packed offsets using the `returned` attribute set to know
    /// which are present, in the order the kernel writes them.
    private static func parseEntry(_ entryBase: UnsafeMutableRawPointer,
                                   total: inout Int64,
                                   subdirs: inout [String]) {
        var p = entryBase.advanced(by: MemoryLayout<UInt32>.size)  // skip entry length

        // attribute_set_t returned = { commonattr, volattr, dirattr, fileattr, forkattr }
        let commonReturned = p.loadUnaligned(as: UInt32.self)
        let fileReturned = p.advanced(by: 3 * MemoryLayout<UInt32>.size).loadUnaligned(as: UInt32.self)
        p = p.advanced(by: 5 * MemoryLayout<UInt32>.size)

        if commonReturned & cmnError != 0 {
            p = p.advanced(by: MemoryLayout<UInt32>.size)          // skip u32 error code
        }

        var name: String?
        if commonReturned & cmnName != 0 {
            // attrreference_t { int32 attr_dataoffset; uint32 attr_length }
            let dataOffset = p.loadUnaligned(as: Int32.self)
            let namePtr = p.advanced(by: Int(dataOffset)).assumingMemoryBound(to: CChar.self)
            name = String(cString: namePtr)
            p = p.advanced(by: MemoryLayout<Int32>.size + MemoryLayout<UInt32>.size)
        }

        var objType: UInt32 = 0
        if commonReturned & cmnObjType != 0 {
            objType = p.loadUnaligned(as: UInt32.self)
            p = p.advanced(by: MemoryLayout<UInt32>.size)
        }

        if objType == vlnk { return }                              // never follow symlinks

        if objType == vdir {
            if let name { subdirs.append(name) }
            return                                                 // dirs have no file size
        }

        if fileReturned & fileAllocSize != 0 {
            let alloc = p.loadUnaligned(as: Int64.self)            // off_t
            if alloc > 0 { total += alloc }
        }
    }
}
#endif
