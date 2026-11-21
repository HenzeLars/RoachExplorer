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

    /// Who owns the item itself. A symlink reports its own owner, not the target's,
    /// the same way the mode bits above do. An account the directory service no
    /// longer knows falls back to its number, which is what Finder shows too.
    static func ownership(of url: URL) -> (owner: String, group: String)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let owner = accountName(info.st_uid) ?? String(info.st_uid)
        let group = groupName(info.st_gid) ?? String(info.st_gid)
        return (owner, group)
    }

    /// When the item itself was created. Not the target of a symlink.
    static func created(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    // `_r` variants: getpwuid and getgrgid share one internal buffer, and this
    // runs on whatever queue asked for the window.
    private static func accountName(_ uid: uid_t) -> String? {
        var record = passwd()
        var buffer = [CChar](repeating: 0, count: 1024)
        var found: UnsafeMutablePointer<passwd>?
        let status = getpwuid_r(uid, &record, &buffer, buffer.count, &found)
        guard status == 0, found != nil else { return nil }
        let name = String(cString: record.pw_name)
        return name.isEmpty ? nil : name
    }

    private static func groupName(_ gid: gid_t) -> String? {
        var record = group()
        var buffer = [CChar](repeating: 0, count: 1024)
        var found: UnsafeMutablePointer<group>?
        let status = getgrgid_r(gid, &record, &buffer, buffer.count, &found)
        guard status == 0, found != nil else { return nil }
        let name = String(cString: record.gr_name)
        return name.isEmpty ? nil : name
    }
}
