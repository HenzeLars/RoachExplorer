import AppKit

/// Mounted volumes and the two things the app does with them: open a server
/// address and eject a volume. Mounting itself is the system's job — the same
/// flow Finder uses — so no sudo and no credentials in our settings.
enum Volumes {
    struct Mounted {
        let url: URL
        let name: String
        /// The filesystem type as the system reports it: "nfs", "smbfs",
        /// "apfs", "msdos", …
        let fileSystem: String
        let isRemovable: Bool
        let isUnmountable: Bool

        var isNetwork: Bool {
            let kind = fileSystem.lowercased()
            return kind.contains("nfs")
                || kind.contains("smb")
                || kind.contains("afp")
                || kind.contains("cifs")
                || kind.contains("webdav")
        }
    }

    /// Every mounted volume, including network shares and disk images.
    static func mounted() -> [Mounted] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeLocalizedNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: []
        ) ?? []
        return urls.compactMap { url in
            var removable: ObjCBool = false
            var writable: ObjCBool = false
            var unmountable: ObjCBool = false
            var type: NSString?
            let described = NSWorkspace.shared.getFileSystemInfo(
                forPath: url.path,
                isRemovable: &removable,
                isWritable: &writable,
                isUnmountable: &unmountable,
                description: nil,
                type: &type
            )
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent
            return Mounted(
                url: url,
                name: name.isEmpty ? url.lastPathComponent : name,
                fileSystem: described ? (type as String? ?? "") : "",
                isRemovable: removable.boolValue,
                isUnmountable: described && unmountable.boolValue
            )
        }
    }

    /// The volumes worth a sidebar row: what a person mounted, not the sealed
    /// system volumes macOS keeps under /System/Volumes. That means anything
    /// under /Volumes (disk images, external disks, shares) plus network
    /// mounts, minus the hidden and Time Machine plumbing.
    static func sidebarVolumes() -> [Mounted] {
        mounted()
            .filter { volume in
                let path = volume.url.standardizedFileURL.path
                guard path != "/", !path.contains("TimeMachine"), !path.contains(".timemachine") else {
                    return false
                }
                if volume.isNetwork { return true }
                return path.hasPrefix("/Volumes/")
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Mount a URL. NFS is mounted directly with `mount_nfs`, which works as
    /// the user and needs no Finder window; SMB goes through the system's own
    /// connect flow. The completion gets the volume to open, or nil.
    static func connect(url: URL, completion: @escaping (URL?) -> Void) {
        if url.scheme?.lowercased() == "nfs" {
            connectNFS(url, completion: completion)
            return
        }
        completion(NSWorkspace.shared.open(url) ? url : nil)
    }

    private static func connectNFS(_ url: URL, completion: @escaping (URL?) -> Void) {
        guard let host = url.host, !host.isEmpty else {
            completion(nil)
            return
        }
        let export = url.path.isEmpty ? "/" : url.path
        guard let mountPoint = mountPoint(for: url) else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/mount_nfs")
            process.arguments = ["\(host):\(export)", mountPoint.path]
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // An unreachable server can leave mount_nfs waiting; do not hang.
            var waited = 0.0
            while process.isRunning, waited < 15 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            if process.isRunning {
                process.terminate()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async { completion(ok ? mountPoint : nil) }
        }
    }

    /// /Volumes/<name> when that is writable, otherwise a private folder.
    private static func mountPoint(for url: URL) -> URL? {
        let name = url.lastPathComponent.isEmpty ? "nfs" : url.lastPathComponent
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let candidate = volumes.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                // /Volumes not writable: fall through to the private folder.
            }
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".roach-mounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let privateCandidate = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: privateCandidate, withIntermediateDirectories: true)
        return privateCandidate
    }

    /// Eject a volume or disk image. AppKit does not report why here, so the
    /// check is the honest one: the mount is gone. Unmounting is asynchronous,
    /// so this waits a few seconds before giving up.
    static func eject(_ url: URL, attempt: Int = 0, completion: @escaping (Error?) -> Void) {
        try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        let path = url.standardizedFileURL.path
        if !mounted().contains(where: { $0.url.standardizedFileURL.path == path }) {
            completion(nil)
            return
        }
        if attempt >= 20 {
            completion(ejectFailure)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            eject(url, attempt: attempt + 1, completion: completion)
        }
    }

    private static let ejectFailure = NSError(
        domain: "RoachExplorer",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The volume could not be ejected. A file on it may still be in use."]
    )
}

/// The connect sheet's address line, turned into a URL. Pure, so the rules can
/// be tested without a window: `host`, `host/share`, `host:/share`, and
/// credentials only for SMB.
enum ServerAddress {
    static func url(scheme: String, address: String, user: String = "", password: String = "") -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host = trimmed
        var path = "/"
        let slash = trimmed.firstIndex(of: "/")
        if let colon = trimmed.firstIndex(of: ":"),
           colon < (slash ?? trimmed.endIndex) {
            // host:/export — the colon belongs to the host, not to a port.
            host = String(trimmed[..<colon])
            let rest = String(trimmed[trimmed.index(after: colon)...])
            path = rest.hasPrefix("/") ? rest : "/" + rest
        } else if let slash {
            host = String(trimmed[..<slash])
            path = String(trimmed[slash...])
        }
        guard !host.isEmpty else { return nil }
        if !path.hasPrefix("/") { path = "/" + path }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        if scheme == "smb" {
            let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                components.user = name
                if !password.isEmpty { components.password = password }
            }
        }
        return components.url
    }
}
