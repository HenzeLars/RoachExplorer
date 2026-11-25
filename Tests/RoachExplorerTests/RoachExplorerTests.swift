import XCTest
@testable import RoachExplorer

/// The pure logic, tested without a window. Anything that needs AppKit views
/// is still checked by hand in the running app.

final class ShellPathTests: XCTestCase {
    func testPlainPathIsQuoted() {
        XCTAssertEqual(ShellPath.escape("/tmp/notes.md"), "'/tmp/notes.md'")
    }

    func testSpaceSurvives() {
        XCTAssertEqual(ShellPath.escape("/tmp/two words.md"), "'/tmp/two words.md'")
    }

    func testSingleQuoteIsClosedAndReopened() {
        XCTAssertEqual(ShellPath.escape("/tmp/it's"), "'/tmp/it'\\''s'")
    }

    func testEmptyPathIsStillQuoted() {
        XCTAssertEqual(ShellPath.escape(""), "''")
    }

    func testJoinGivesOneArgumentPerFile() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a b"),
            URL(fileURLWithPath: "/tmp/c"),
        ]
        XCTAssertEqual(ShellPath.join(urls), "'/tmp/a b' '/tmp/c'")
    }

    func testJoinOfNothingIsEmpty() {
        XCTAssertEqual(ShellPath.join([]), "")
    }
}

final class FormatTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Format.size(0), "0 bytes")
        XCTAssertEqual(Format.size(1), "1 byte")
        XCTAssertEqual(Format.size(1023), "1023 bytes")
    }

    func testWholeUnitsDropTheDecimal() {
        XCTAssertEqual(Format.size(1024), "1 KB")
        XCTAssertEqual(Format.size(2 * 1024), "2 KB")
        XCTAssertEqual(Format.size(1024 * 1024), "1 MB")
        XCTAssertEqual(Format.size(1024 * 1024 * 1024), "1 GB")
        XCTAssertEqual(Format.size(1024 * 1024 * 1024 * 1024), "1 TB")
    }

    func testGroupedBytesSaysByteForOne() {
        XCTAssertEqual(Format.groupedBytes(1), "1 byte")
        XCTAssertTrue(Format.groupedBytes(4100).hasSuffix(" bytes"))
    }
}

final class DropTargetTests: XCTestCase {
    func testNothingToDrop() {
        XCTAssertFalse(DropTarget.canDrop([], into: URL(fileURLWithPath: "/tmp")))
    }

    func testCannotDropIntoItself() {
        let folder = URL(fileURLWithPath: "/tmp/self")
        XCTAssertFalse(DropTarget.canDrop([folder], into: folder))
    }

    func testCannotDropIntoItsOwnChild() {
        let folder = URL(fileURLWithPath: "/tmp/self")
        XCTAssertFalse(DropTarget.canDrop([folder], into: folder.appendingPathComponent("child")))
    }

    func testSiblingIsFine() {
        XCTAssertTrue(
            DropTarget.canDrop(
                [URL(fileURLWithPath: "/tmp/a/one")],
                into: URL(fileURLWithPath: "/tmp/a/two")
            )
        )
    }

    /// `/tmp/selfie` starts with `/tmp/self` but is not inside it.
    func testNamePrefixIsNotAParent() {
        XCTAssertTrue(
            DropTarget.canDrop(
                [URL(fileURLWithPath: "/tmp/self")],
                into: URL(fileURLWithPath: "/tmp/selfie")
            )
        )
    }

    func testFolderResolvingWantsARealDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("roach-tests-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("folder", isDirectory: true)
        let file = base.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertNotNil(DropTarget.folder(resolving: folder))
        XCTAssertNil(DropTarget.folder(resolving: file))
        XCTAssertNil(DropTarget.folder(resolving: base.appendingPathComponent("missing")))
    }
}

final class AliasTests: XCTestCase {
    func testNameReadsLikeFinder() {
        XCTAssertEqual(Alias.name(for: "notes.md", number: 1), "notes.md alias")
        XCTAssertEqual(Alias.name(for: "notes.md", number: 2), "notes.md alias 2")
        XCTAssertEqual(Alias.name(for: "techno", number: 3), "techno alias 3")
    }

    func testWritesAnAliasThatResolves() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let original = base.appendingPathComponent("notes.md")
        try Data("x".utf8).write(to: original)

        let alias = try Alias.write(for: original, in: base, taken: [])
        XCTAssertEqual(alias.lastPathComponent, "notes.md alias")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))

        let resolved = try URL(resolvingAliasFileAt: alias)
        XCTAssertEqual(resolved.standardizedFileURL.path, original.standardizedFileURL.path)
    }

    func testASecondAliasGetsANumber() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let original = base.appendingPathComponent("techno")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)

        let first = try Alias.write(for: original, in: base, taken: [])
        let second = try Alias.write(for: original, in: base, taken: [first])
        XCTAssertEqual(first.lastPathComponent, "techno alias")
        XCTAssertEqual(second.lastPathComponent, "techno alias 2")
        XCTAssertEqual(
            try URL(resolvingAliasFileAt: second).standardizedFileURL.path,
            original.standardizedFileURL.path
        )
    }

    func testAnAliasOfAFolderResolvesToTheFolder() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("release_cycle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let alias = try Alias.write(for: folder, in: base, taken: [])
        let resolved = try URL(resolvingAliasFileAt: alias)
        XCTAssertEqual(resolved.standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    private func temporaryFolder() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("roach-alias-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

/// The second line under a link row. The link text on disk is whatever `ln -s`
/// was given, so a relative one has to be resolved before it is shown.
/// The MRU list behind per-folder views. Pure ordering rules only.
final class FolderViewEntryTests: XCTestCase {
    private func settings(_ nameWidth: Double) -> FolderViewSettings {
        FolderViewSettings(
            sortColumn: "Name",
            sortAscending: true,
            columnWidths: ["Name": nameWidth, "Date modified": 120, "Size": 80, "Kind": 180]
        )
    }

    func testANewFolderGoesToTheFront() {
        let list = FolderViewEntry.updating([], path: "/a", settings: settings(100), cap: 100)
        XCTAssertEqual(list.map(\.path), ["/a"])
    }

    func testTheSameFolderMovesToTheFrontWithoutDuplicates() {
        let start = FolderViewEntry.updating([], path: "/a", settings: settings(100), cap: 100)
        let withB = FolderViewEntry.updating(start, path: "/b", settings: settings(90), cap: 100)
        let again = FolderViewEntry.updating(withB, path: "/a", settings: settings(120), cap: 100)

        XCTAssertEqual(again.map(\.path), ["/a", "/b"])
        XCTAssertEqual(again.first?.settings.columnWidths["Name"], 120)
    }

    func testTheOldestFallOffAtTheCap() {
        var list: [FolderViewEntry] = []
        for index in 0..<105 {
            list = FolderViewEntry.updating(list, path: "/f\(index)", settings: settings(100), cap: 100)
        }

        XCTAssertEqual(list.count, 100)
        XCTAssertEqual(list.first?.path, "/f104")
        XCTAssertEqual(list.last?.path, "/f5")
        XCTAssertFalse(list.contains { $0.path == "/f0" })
    }

    func testDefaultsAreNotWorthAnEntry() {
        XCTAssertEqual(settings(300), FolderViewSettings.default)
        XCTAssertNotEqual(settings(301), FolderViewSettings.default)
    }

    func testMixingFoldersAndFilesIsNotTheDefault() {
        let mixed = FolderViewSettings(
            sortColumn: "Name",
            sortAscending: true,
            columnWidths: FolderViewSettings.default.columnWidths,
            foldersFirst: false
        )
        XCTAssertNotEqual(mixed, FolderViewSettings.default)
    }

    /// Files written before "folders first" existed must still decode, as on.
    func testAnOlderEntryWithoutFoldersFirstDecodesAsOn() throws {
        let json = """
        {"path":"/old","settings":{"sortColumn":"Name","sortAscending":true,
         "columnWidths":{"Name":300,"Date modified":120,"Size":80,"Kind":180}}}
        """
        let entry = try JSONDecoder().decode(FolderViewEntry.self, from: Data(json.utf8))
        XCTAssertTrue(entry.settings.foldersFirst)
    }
}

final class LinkTargetTests: XCTestCase {
    func testAnAbsoluteLinkKeepsItsPath() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let original = base.appendingPathComponent("notes.md")
        try Data("x".utf8).write(to: original)
        let link = base.appendingPathComponent("abs-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)

        XCTAssertEqual(FileSystem.item(at: link)?.linkTarget, original.standardizedFileURL.path)
    }

    func testARelativeLinkIsResolvedAgainstItsFolder() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("rel-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "sub")

        XCTAssertEqual(FileSystem.item(at: link)?.linkTarget, folder.standardizedFileURL.path)
    }

    func testABrokenLinkStillShowsWhereItPoints() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/nowhere/at/all"
        )

        XCTAssertEqual(FileSystem.item(at: link)?.linkTarget, "/nowhere/at/all")
    }

    func testTheHomeFolderIsShortenedToATilde() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("home-link")
        let home = FileManager.default.homeDirectoryForCurrentUser
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: home.appendingPathComponent("Documents").path
        )

        XCTAssertEqual(FileSystem.item(at: link)?.linkTarget, "~/Documents")
    }

    func testAnOrdinaryFileHasNoTarget() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)

        XCTAssertNil(FileSystem.item(at: file)?.linkTarget)
    }

    private func temporaryFolder() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("roach-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

final class SearchTests: XCTestCase {
    func testMatchesIsACaseInsensitiveSubstring() {
        XCTAssertTrue(Search.matches(name: "notes.md", query: "NOTES"))
        XCTAssertTrue(Search.matches(name: "DeepNotes.md", query: "notes"))
        XCTAssertTrue(Search.matches(name: "notes.md", query: ".md"))
        XCTAssertFalse(Search.matches(name: "notes.md", query: "todo"))
    }

    func testMatchesIgnoresAccents() {
        XCTAssertTrue(Search.matches(name: "über.txt", query: "uber"))
        XCTAssertTrue(Search.matches(name: "Über.txt", query: "UBER"))
    }

    func testAnEmptyQueryMatchesNothing() {
        XCTAssertFalse(Search.matches(name: "notes.md", query: ""))
        XCTAssertFalse(Search.matches(name: "notes.md", query: "   "))
    }

    func testTheWalkFindsNestedNames() {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = base.appendingPathComponent("deep/a/b", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let photos = base.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for file in [
            base.appendingPathComponent("notes.md"),
            photos.appendingPathComponent("notes.txt"),
            nested.appendingPathComponent("deepnotes.md"),
            base.appendingPathComponent("other.txt"),
        ] {
            try? Data("x".utf8).write(to: file)
        }

        var found: [String] = []
        let done = expectation(description: "walk finished")
        _ = Search.start(below: base, query: "notes") { batch in
            found.append(contentsOf: batch.map(\.name))
        } onFinish: { outcome in
            XCTAssertFalse(outcome.cancelled)
            XCTAssertFalse(outcome.hitLimit)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(Set(found), ["notes.md", "notes.txt", "deepnotes.md"])
    }

    func testTheWalkKeepsHiddenFolders() {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let hidden = base.appendingPathComponent(".secrets", isDirectory: true)
        try? FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: hidden.appendingPathComponent("notes.md"))

        var found: [String] = []
        let done = expectation(description: "walk finished")
        _ = Search.start(below: base, query: "notes") { batch in
            found.append(contentsOf: batch.map(\.name))
        } onFinish: { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(found, ["notes.md"])
    }

    private func temporaryFolder() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("roach-search-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

final class CockroachNameTests: XCTestCase {    func testOffersANameFromTheList() {
        XCTAssertTrue(CockroachName.all.contains(CockroachName.next(avoiding: [])))
    }

    func testAvoidsTakenNames() {
        let taken = Array(CockroachName.all.dropLast())
        XCTAssertEqual(CockroachName.next(avoiding: taken), CockroachName.all.last)
    }

    func testAvoidsTakenNamesWhateverTheCase() {
        let taken = CockroachName.all.dropLast().map { $0.lowercased() }
        XCTAssertEqual(CockroachName.next(avoiding: taken), CockroachName.all.last)
    }

    func testNumbersWhenEveryNameIsTaken() throws {
        let name = CockroachName.next(avoiding: CockroachName.all)
        let base = try XCTUnwrap(CockroachName.all.first { name.hasPrefix($0) })
        let number = try XCTUnwrap(Int(name.dropFirst(base.count)))
        XCTAssertGreaterThanOrEqual(number, 2)
    }
}

/// The connect sheet's address rules, without a window.
final class ServerAddressTests: XCTestCase {
    func testNFSHostAndShare() {
        let url = ServerAddress.url(scheme: "nfs", address: "192.168.1.223/share")
        XCTAssertEqual(url?.absoluteString, "nfs://192.168.1.223/share")
    }

    func testNFSColonForm() {
        let url = ServerAddress.url(scheme: "nfs", address: "192.168.1.223:/export")
        XCTAssertEqual(url?.absoluteString, "nfs://192.168.1.223/export")
    }

    func testNFSHostOnlyGetsTheRoot() {
        let url = ServerAddress.url(scheme: "nfs", address: "nas.local")
        XCTAssertEqual(url?.absoluteString, "nfs://nas.local/")
    }

    func testSMBWithCredentials() {
        let url = ServerAddress.url(scheme: "smb", address: "server/share", user: "lars", password: "secret")
        XCTAssertEqual(url?.absoluteString, "smb://lars:secret@server/share")
    }

    func testSMBPasswordWithSpecialsIsEncoded() {
        let url = ServerAddress.url(scheme: "smb", address: "server/share", user: "lars", password: "p@ss word")
        XCTAssertEqual(url?.absoluteString, "smb://lars:p%40ss%20word@server/share")
    }

    func testCredentialsAreIgnoredForNFS() {
        let url = ServerAddress.url(scheme: "nfs", address: "nas/export", user: "lars", password: "secret")
        XCTAssertEqual(url?.absoluteString, "nfs://nas/export")
    }

    func testAnEmptyAddressIsNoURL() {
        XCTAssertNil(ServerAddress.url(scheme: "smb", address: "   "))
    }
}

/// The recent-server list: newest first, no duplicates, capped.
final class RecentServersTests: XCTestCase {
    func testANewAddressGoesToTheFront() {
        let list = RecentServers.adding([], "nas.local/share")
        XCTAssertEqual(list, ["nas.local/share"])
    }

    func testTheSameAddressMovesToTheFrontWithoutDuplicating() {
        let start = RecentServers.adding([], "a")
        let withB = RecentServers.adding(start, "b")
        let again = RecentServers.adding(withB, "a")
        XCTAssertEqual(again, ["a", "b"])
    }

    func testTheListStopsAtTwenty() {
        var list: [String] = []
        for index in 0..<25 {
            list = RecentServers.adding(list, "host\(index)")
        }
        XCTAssertEqual(list.count, 20)
        XCTAssertEqual(list.first, "host24")
        XCTAssertEqual(list.last, "host5")
    }

    func testAnOlderSettingsFileDecodesWithoutTheList() throws {
        let json = """
        {"lastPath":"/tmp","favorites":[]}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.recentServers, [])
    }
}
