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
}

enum FileSystem {
    /// All entries of `directory`, dotfiles included. Folders first,
    /// then case-insensitive name order.
    static func listItems(in directory: URL) -> [FileItem] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .typeIdentifierKey,
        ]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )) ?? []

        let items = urls.compactMap { url -> FileItem? in
            let values = (try? url.resourceValues(forKeys: keys)) ?? URLResourceValues()
            let isFolder = values.isDirectory ?? false
            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isFolder: isFolder,
                isPackage: (values.isPackage ?? false) && isFolder,
                isLink: values.isSymbolicLink ?? false,
                isHidden: url.lastPathComponent.hasPrefix("."),
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? Date(),
                kind: kind(for: url, isFolder: isFolder, typeIdentifier: values.typeIdentifier)
            )
        }

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
