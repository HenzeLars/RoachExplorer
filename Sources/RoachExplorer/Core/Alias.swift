import Foundation

/// Finder-style alias files. Not symlinks: an alias keeps following the
/// original when it is renamed or moved on the same volume. Written with the
/// public bookmark-file API, so no Carbon and no private calls.
enum Alias {
    /// `notes.md` → `notes.md alias`, then `notes.md alias 2`.
    static func name(for source: String, number: Int) -> String {
        number == 1 ? source + " alias" : source + " alias \(number)"
    }

    /// Writes one alias into `folder` and returns its URL. `taken` is the
    /// folder as the window currently sees it, so a name is not reused
    /// even before the next reload notices it.
    static func write(for source: URL, in folder: URL, taken: [URL]) throws -> URL {
        let existing = Set(taken.map { $0.standardizedFileURL.path })
        var number = 1
        var destination = folder.appendingPathComponent(name(for: source.lastPathComponent, number: number))
        while existing.contains(destination.standardizedFileURL.path)
            || FileManager.default.fileExists(atPath: destination.path) {
            number += 1
            destination = folder.appendingPathComponent(name(for: source.lastPathComponent, number: number))
        }
        let data = try source.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(data, to: destination)
        return destination
    }
}
