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
