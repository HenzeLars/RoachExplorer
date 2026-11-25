import Foundation

/// The container. ZIP is always deflate-compressed inside; TAR is the
/// container that the compression choice applies to.
enum ArchiveFormat: Int, CaseIterable {
    case zip = 0
    case tar = 1

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "TAR"
        }
    }
}

/// The compressor used with a TAR container. Ignored for ZIP.
enum ArchiveCompression: Int, CaseIterable {
    case none = 0
    case gzip = 1
    case bzip2 = 2
    case xz = 3

    var title: String {
        switch self {
        case .none: return "None"
        case .gzip: return "gzip (.gz)"
        case .bzip2: return "bzip2 (.bz2)"
        case .xz: return "xz (.xz)"
        }
    }
}

/// A chosen format plus compression, and the file extension it implies.
struct ArchiveSpec {
    let format: ArchiveFormat
    let compression: ArchiveCompression

    /// Appended to the typed stem: `.zip`, `.tar`, `.tar.gz`, `.tar.bz2`, `.tar.xz`.
    var fileExtension: String {
        switch format {
        case .zip:
            return ".zip"
        case .tar:
            switch compression {
            case .none: return ".tar"
            case .gzip: return ".tar.gz"
            case .bzip2: return ".tar.bz2"
            case .xz: return ".tar.xz"
            }
        }
    }
}

/// Naming and process construction for archiving. No views, so it is unit-tested.
enum Archive {
    static let dittoPath = "/usr/bin/ditto"
    static let tarPath = "/usr/bin/tar"

    /// The default stem for the typed name: a single item keeps its own name
    /// (a file loses its extension, a folder keeps it whole); several items
    /// become "Archive".
    static func defaultStem(for items: [FileItem]) -> String {
        guard items.count == 1 else { return "Archive" }
        let item = items[0]
        let name = item.url.lastPathComponent
        if !item.isFolder {
            let ns = name as NSString
            if !ns.pathExtension.isEmpty { return ns.deletingPathExtension }
        }
        return name
    }

    /// `name 2.ext`, `name 3.ext`, … — the first that is free on disk.
    static func uniqueName(stem: String, ext: String, in folder: URL) -> String {
        var candidate = stem + ext
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(stem) \(number)\(ext)"
            number += 1
        }
        return candidate
    }

    /// The executable and arguments. `name` is the archive file name with its
    /// extension; `sources` are absolute URLs that all live in `folder`.
    static func command(spec: ArchiveSpec, sources: [URL], folder: URL, name: String) -> (tool: String, arguments: [String]) {
        let destination = folder.appendingPathComponent(name).path
        switch spec.format {
        case .zip:
            // ditto keeps resource forks and the source folder names.
            let arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent"]
                + sources.map(\.path)
                + [destination]
            return (dittoPath, arguments)
        case .tar:
            let flag: String
            switch spec.compression {
            case .none: flag = "-cf"
            case .gzip: flag = "-czf"
            case .bzip2: flag = "-cjf"
            case .xz: flag = "-cJf"
            }
            // Run from the folder, so the archive holds relative names, not
            // the full path. The destination is absolute, so -C does not move it.
            let names = sources.map { $0.lastPathComponent }
            let arguments = [flag, destination, "-C", folder.path] + names
            return (tarPath, arguments)
        }
    }
}