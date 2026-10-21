import XCTest
import AVFoundation
@testable import PTBrowser

final class LibraryRepositoryTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL!
    private var repository: LibraryRepository!
    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = sandbox.appendingPathComponent("SharedFiles")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = LibraryRepository(root: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: sandbox) }
    private func fixture(_ name: String = "private-photo.jpg", data: Data = Data(repeating: 71, count: 2000)) throws -> URL {
        let source = sandbox.appendingPathComponent(name)
        try data.write(to: source)
        return source
    }
    func testReinstalledApplicationReadsPublicAndUnlocksOldFolder() async throws {
        _ = try await repository.snapshot()
        let source = try fixture()
        let imported = try await repository.importFile(source)
        _ = try await repository.importFile(try fixture("ordinary.jpg"))
        try await repository.createVault(password: "portable-password")
        try await repository.encrypt(imported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(imported.name).path))
        let indexText = try String(contentsOf: root.appendingPathComponent(".ptbrowser/vault.json"))
        XCTAssertFalse(indexText.contains(imported.name))
        let publicIndex = try String(contentsOf: root.appendingPathComponent(".ptbrowser/library.json"))
        XCTAssertFalse(publicIndex.contains(imported.name))
        await repository.lock()
        let reopened = LibraryRepository(root: root) // no bundle-specific state, keychain or bookmark needed
        let locked = try await reopened.snapshot()
        XCTAssertTrue(locked.hasVault); XCTAssertFalse(locked.unlocked)
        XCTAssertEqual(locked.items.map(\.name), ["ordinary.jpg"])
        do { try await reopened.unlock(password: "wrong-password"); XCTFail("Wrong password accepted") } catch {}
        try await reopened.unlock(password: "portable-password")
        let open = try await reopened.snapshot()
        let hidden = try XCTUnwrap(open.items.first(where: \.isEncrypted))
        let clear = try await reopened.playableURL(hidden)
        XCTAssertEqual(try Data(contentsOf: clear), try Data(contentsOf: source))
        await reopened.lock()
        XCTAssertFalse(FileManager.default.fileExists(atPath: clear.path))
        do { _ = try await reopened.playableURL(hidden); XCTFail("Locked access succeeded") } catch {}
        try await reopened.unlock(password: "portable-password")
        try await reopened.restore(hidden)
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.items.count, 2); XCTAssertFalse(restored.items.contains(where: \.isEncrypted))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(imported.name)), try Data(contentsOf: source))
    }
    func testFoldersRenameFavoriteCollisionAndHashValidation() async throws {
        _ = try await repository.snapshot()
        try await repository.createFolder("Trips")
        let first = try await repository.importFile(try fixture(), folder: "Trips")
        let second = try await repository.importFile(try fixture(), folder: "Trips")
        XCTAssertNotEqual(first.relativePath, second.relativePath)
        try await repository.favorite(first)
        try await repository.rename(first, name: "renamed", folder: "")
        let snapshot = try await repository.snapshot()
        let updated = try XCTUnwrap(snapshot.items.first { $0.id == first.id })
        XCTAssertTrue(updated.favorite); XCTAssertEqual(updated.name, "renamed.jpg")
        _ = try await repository.verify(updated)
        try Data("modified-content".utf8).write(to: root.appendingPathComponent(updated.relativePath))
        do { _ = try await repository.verify(updated); XCTFail("Mutation was not detected") } catch {}
        try await repository.delete(second)
        let final = try await repository.snapshot()
        XCTAssertEqual(final.items.count, 1)
    }
    func testExpectedHashMismatchNeverCommitsFile() async throws {
        _ = try await repository.snapshot()
        do { _ = try await repository.importFile(try fixture(), expectedSHA256: String(repeating: "0", count: 64)); XCTFail("Incorrect hash accepted") } catch {}
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
    }
    func testPackageEncryptionPreservesNestedResources() async throws {
        _ = try await repository.snapshot()
        let package = sandbox.appendingPathComponent("movie.movpkg")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("video"), withIntermediateDirectories: true)
        try Data("#EXTM3U".utf8).write(to: package.appendingPathComponent("index.m3u8"))
        let segment = Data(repeating: 9, count: VaultCrypto.chunkSize + 50)
        try segment.write(to: package.appendingPathComponent("video/segment.ts"))
        let item = try await repository.importFile(package)
        try await repository.createVault(password: "package-password")
        try await repository.encrypt(item)
        let snapshot = try await repository.snapshot()
        let hidden = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(hidden.parts?.count, 2)
        let playable = try await repository.playableURL(hidden)
        XCTAssertEqual(try Data(contentsOf: playable.appendingPathComponent("video/segment.ts")), segment)
        try await repository.restore(hidden)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("movie.movpkg/video/segment.ts")), segment)
    }
    func testPathsCannotEscapeSelectedFolder() async throws {
        XCTAssertFalse(LibraryRepository.validRelativePath("../photo.jpg"))
        XCTAssertFalse(LibraryRepository.validRelativePath("/photo.jpg"))
        XCTAssertFalse(LibraryRepository.validRelativePath(".ptbrowser/vault.json"))
        XCTAssertFalse(LibraryRepository.validRelativePath("folder/../photo.jpg"))
        XCTAssertTrue(LibraryRepository.validRelativePath("Trips/photo.jpg"))
        _ = try await repository.snapshot()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: sandbox)
        do { _ = try await repository.importFile(try fixture(), folder: "escape"); XCTFail("Symlink escape accepted") } catch {}
        do { _ = try await repository.importFile(try fixture(), folder: ".."); XCTFail("Traversal accepted") } catch {}
    }
    func testEncryptedVideoRemainsPlayableAfterReopeningFolder() async throws {
        _ = try await repository.snapshot()
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Playback-Test", withExtension: "mp4"))
        let item = try await repository.importFile(source)
        try await repository.createVault(password: "video-test-password")
        try await repository.encrypt(item)
        await repository.lock()
        let reopened = LibraryRepository(root: root)
        _ = try await reopened.snapshot()
        try await reopened.unlock(password: "video-test-password")
        let snapshot = try await reopened.snapshot()
        let hidden = try XCTUnwrap(snapshot.items.first)
        let playbackURL = try await reopened.playableURL(hidden)
        let asset = AVURLAsset(url: playbackURL)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(playable)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.1)
        XCTAssertEqual(try VaultCrypto.hash(playbackURL), try VaultCrypto.hash(source))
    }

    func testMP4InSelectedFolderAliasCanBeOpenedEncryptedAndRestoredAfterScan() async throws {
        let alias = sandbox.appendingPathComponent("FolderShortcut", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        _ = try await repository.snapshot()
        try await repository.createVault(password: "alias-video-password")
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Playback-Test", withExtension: "mp4"))
        let imported = try await repository.importFile(source, preferredName: "视频 #1 100% ?.mp4")
        try await repository.favorite(imported)
        let selected = LibraryRepository(root: alias)
        let scanned = try await selected.snapshot()
        let item = try XCTUnwrap(scanned.items.first)
        XCTAssertEqual(item.relativePath, imported.name)
        XCTAssertEqual(item.id, imported.id)
        XCTAssertTrue(item.favorite)
        let originalURL = try await selected.playableURL(item)
        XCTAssertEqual(try Data(contentsOf: originalURL), try Data(contentsOf: source))
        let playable = try await AVURLAsset(url: originalURL).load(.isPlayable)
        XCTAssertTrue(playable)
        try await selected.unlock(password: "alias-video-password")
        try await selected.encrypt(item)
        await selected.lock()
        let reopened = LibraryRepository(root: alias)
        _ = try await reopened.snapshot()
        try await reopened.unlock(password: "alias-video-password")
        let unlocked = try await reopened.snapshot()
        let hidden = try XCTUnwrap(unlocked.items.first)
        let decrypted = try await reopened.playableURL(hidden)
        XCTAssertEqual(try Data(contentsOf: decrypted), try Data(contentsOf: source))
        try await reopened.restore(hidden)
        let restored = try await reopened.snapshot()
        let restoredItem = try XCTUnwrap(restored.items.first)
        let restoredURL = try await reopened.playableURL(restoredItem)
        XCTAssertEqual(try Data(contentsOf: restoredURL), try Data(contentsOf: source))
    }

    func testRescanRepairsLegacySlicedPathsWithoutLosingFileMetadata() async throws {
        _ = try await repository.snapshot()
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Playback-Test", withExtension: "mp4"))
        let imported = try await repository.importFile(source)
        let alias = sandbox.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let scanner = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
        let physical = try XCTUnwrap(scanner.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == imported.name })
        let oldPath = String(physical.path.dropFirst(alias.path.count + 1))
        XCTAssertNotEqual(oldPath, imported.relativePath)
        var legacy = imported
        legacy.relativePath = oldPath; legacy.favorite = true
        try JSONEncoder().encode(PublicIndex(records: [oldPath: legacy])).write(to: root.appendingPathComponent(".ptbrowser/library.json"), options: .atomic)
        let reopened = LibraryRepository(root: alias)
        let snapshot = try await reopened.snapshot()
        let repaired = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(repaired.relativePath, imported.name)
        XCTAssertEqual(repaired.id, imported.id)
        XCTAssertTrue(repaired.favorite)
        XCTAssertEqual(repaired.sha256, imported.sha256)
        let playable = try await reopened.playableURL(repaired)
        XCTAssertEqual(try Data(contentsOf: playable), try Data(contentsOf: source))
        let saved = try JSONDecoder().decode(PublicIndex.self, from: Data(contentsOf: root.appendingPathComponent(".ptbrowser/library.json")))
        XCTAssertNil(saved.records[oldPath])
        XCTAssertEqual(saved.records[imported.name]?.id, imported.id)
    }

    func testEmptyAliasedFolderAndNestedPackageUseCorrectPaths() async throws {
        let alias = sandbox.appendingPathComponent("NewFolderShortcut", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let selected = LibraryRepository(root: alias)
        _ = try await selected.snapshot()
        try await selected.createFolder("相册 #1")
        let package = sandbox.appendingPathComponent("clip.movpkg")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("video"), withIntermediateDirectories: true)
        try Data("#EXTM3U".utf8).write(to: package.appendingPathComponent("index.m3u8"))
        let payload = Data(repeating: 10, count: 500)
        try payload.write(to: package.appendingPathComponent("video/segment.ts"))
        let imported = try await selected.importFile(package, folder: "相册 #1")
        let snapshot = try await selected.snapshot()
        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(item.relativePath, "相册 #1/clip.movpkg")
        XCTAssertEqual(item.id, imported.id)
        try await selected.createVault(password: "package-test-password")
        try await selected.encrypt(item)
        let encrypted = try await selected.snapshot()
        let hidden = try XCTUnwrap(encrypted.items.first)
        XCTAssertEqual(Set(hidden.parts?.map(\.path) ?? []), ["index.m3u8", "video/segment.ts"])
        let clear = try await selected.playableURL(hidden)
        XCTAssertEqual(try Data(contentsOf: clear.appendingPathComponent("video/segment.ts")), payload)
    }

}
