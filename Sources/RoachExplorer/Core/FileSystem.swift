import Foundation
import UniformTypeIdentifiers

/// One row in the file list.
struct FileItem {
    let url: URL
    let name: String
    let isFolder: Bool
    let isPackage: Bool
    let isLink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let kind: String
    /// Where a symbolic link points, as an absolute path with the home folder
    /// shortened to `~`. Nil for everything that is not a link.
    let linkTarget: String?
}

enum FileSystem {
    /// The resource keys the list and the search both need.
    static let itemKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .typeIdentifierKey,
    ]

    /// One row, from a URL. Returns nil only for a path that cannot be read.
    static func item(at url: URL) -> FileItem? {
        let values = (try? url.resourceValues(forKeys: itemKeys)) ?? URLResourceValues()
        let isFolder = values.isDirectory ?? false
        let isLink = values.isSymbolicLink ?? false
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isFolder: isFolder,
            isPackage: (values.isPackage ?? false) && isFolder,
            isLink: isLink,
            isHidden: url.lastPathComponent.hasPrefix("."),
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? Date(),
            kind: kind(for: url, isFolder: isFolder, typeIdentifier: values.typeIdentifier),
            linkTarget: isLink ? linkTarget(for: url) : nil
        )
    }

    /// A link stores whatever text was passed to `ln -s`, which can be relative
    /// to the link's own folder. Resolve that, then shorten `/Users/name` to `~`
    /// so the second line stays readable.
    private static func linkTarget(for url: URL) -> String? {
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        let absolute = raw.hasPrefix("/")
            ? raw
            : url.deletingLastPathComponent().appendingPathComponent(raw).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if absolute == home { return "~" }
        if absolute.hasPrefix(home + "/") {
            return "~" + String(absolute.dropFirst(home.count))
        }
        return absolute
    }

    /// All entries of `directory`, dotfiles included. Folders first,
    /// then case-insensitive name order.
    static func listItems(in directory: URL) -> [FileItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(itemKeys),
            options: []
        )) ?? []

        let items = urls.compactMap { item(at: $0) }

        return items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The system's own type name ("Markdown Document", "Folder", "PNG image"),
    /// not a homemade extension table. Spotlight first, then the type identifier,
    /// then a plain fallback.
    private static func kind(for url: URL, isFolder: Bool, typeIdentifier: String?) -> String {
        if let kind = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemKind") as? String,
           !kind.isEmpty {
            return kind
        }
        if isFolder { return "Folder" }
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            return type.localizedDescription ?? "File"
        }
        return "File"
    }
}
