import XCTest
import CryptoKit
@testable import PTBrowser

final class VaultCryptoTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testChunkRoundTripAndIndependentNonces() throws {
        let key = SymmetricKey(size: .bits256)
        for size in [0, 1, VaultCrypto.chunkSize, VaultCrypto.chunkSize * 2 + 37] {
            let data = Data((0..<size).map { UInt8($0 % 251) })
            let source = directory.appendingPathComponent("source")
            let encrypted = directory.appendingPathComponent("encrypted")
            let other = directory.appendingPathComponent("other")
            let restored = directory.appendingPathComponent("restored")
            try data.write(to: source)
            let (bytes, digest) = try VaultCrypto.encrypt(source: source, destination: encrypted, key: key, identity: "vault/file")
            _ = try VaultCrypto.encrypt(source: source, destination: other, key: key, identity: "vault/file")
            XCTAssertNotEqual(try Data(contentsOf: encrypted), try Data(contentsOf: other))
            try VaultCrypto.decrypt(source: encrypted, destination: restored, key: key, identity: "vault/file", expectedBytes: bytes, expectedHash: digest)
            XCTAssertEqual(try Data(contentsOf: restored), data)
        }
    }
    func testTamperingTruncationTrailingDataAndWrongIdentityFailClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let source = directory.appendingPathComponent("source")
        let encrypted = directory.appendingPathComponent("encrypted")
        let restored = directory.appendingPathComponent("restored")
        try Data(repeating: 42, count: VaultCrypto.chunkSize + 90).write(to: source)
        let (bytes, digest) = try VaultCrypto.encrypt(source: source, destination: encrypted, key: key, identity: "correct")
        let original = try Data(contentsOf: encrypted)
        var flipped = original; flipped[30] ^= 0xff
        var finalFlag = original; finalFlag[12] = 1
        var trailing = original; trailing.append(0)
        for invalid in [flipped, finalFlag, Data(original.dropLast()), trailing, Data(original.prefix(8))] {
            try invalid.write(to: encrypted)
            XCTAssertThrowsError(try VaultCrypto.decrypt(source: encrypted, destination: restored, key: key, identity: "correct", expectedBytes: bytes, expectedHash: digest))
            XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
        }
        try original.write(to: encrypted)
        XCTAssertThrowsError(try VaultCrypto.decrypt(source: encrypted, destination: restored, key: key, identity: "different-file", expectedBytes: bytes, expectedHash: digest))
        XCTAssertThrowsError(try VaultCrypto.decrypt(source: encrypted, destination: restored, key: SymmetricKey(size: .bits256), identity: "correct", expectedBytes: bytes, expectedHash: digest))
        XCTAssertThrowsError(try VaultCrypto.decrypt(source: encrypted, destination: restored, key: key, identity: "correct", expectedBytes: bytes + 1, expectedHash: digest))
    }
    func testPortablePasswordDerivationAndAuthenticatedIndex() throws {
        let salt = try VaultCrypto.randomSalt()
        let first = try VaultCrypto.derive(password: "中文密码🔒123456", salt: salt, rounds: VaultCrypto.rounds)
        let second = try VaultCrypto.derive(password: "中文密码🔒123456", salt: salt, rounds: VaultCrypto.rounds)
        let sealed = try VaultCrypto.sealIndex([], key: first, vaultID: "portable")
        let envelope = VaultEnvelope(id: "portable", salt: salt, rounds: VaultCrypto.rounds, index: sealed)
        XCTAssertEqual(try VaultCrypto.openIndex(envelope, key: second), [])
        let wrong = try VaultCrypto.derive(password: "wrong-password", salt: salt, rounds: VaultCrypto.rounds)
        XCTAssertThrowsError(try VaultCrypto.openIndex(envelope, key: wrong))
        var altered = envelope; altered.id = "swapped"
        XCTAssertThrowsError(try VaultCrypto.openIndex(altered, key: second))
        XCTAssertThrowsError(try VaultCrypto.derive(password: "password", salt: salt, rounds: 1))
    }
}
