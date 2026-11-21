import Darwin
import Foundation

/// The nine mode bits, read with `lstat` so a symlink is not followed.
enum Permissions {
    static func mode(of url: URL) -> UInt16? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return UInt16(info.st_mode & 0o777)
    }

    /// A real directory. A symlink, even to a folder, is not one.
    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func setMode(_ mode: UInt16, of url: URL) throws {
        var bits = mode
        if isDirectory(url) {
            bits |= 0o111
        }
        if lchmod(url.path, mode_t(bits)) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(errno)),
            ])
        }
    }

    static func symbolic(_ mode: UInt16) -> String {
        let letters = ["r", "w", "x"]
        var text = ""
        for index in 0..<9 {
            let bit = UInt16(1 << (8 - index))
            text.append((mode & bit) == 0 ? "-" : letters[index % 3])
            if index == 2 || index == 5 { text.append(" ") }
        }
        return text
    }
}
