import Foundation
import CryptoKit
import CommonCrypto

/// Portable, versioned format. Password is never stored, and no keychain/bundle ID is involved.
enum VaultCrypto {
    static let rounds: UInt32 = 310_000
    static let chunkSize = 1_048_576
    static let magic = Data("PTBV0001".utf8)

    static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PTError.message("无法生成安全随机数") }
        return Data(bytes)
    }

    static func derive(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        guard salt.count == 32, rounds >= 100_000, rounds <= 2_000_000 else { throw PTError.message("加密目录的参数无效或版本不兼容") }
        let passwordBytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw PTError.message("密码密钥派生失败") }
        return SymmetricKey(data: output)
    }

    static func sealIndex(_ items: [MediaItem], key: SymmetricKey, vaultID: String) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(items), using: key, authenticating: Data(vaultID.utf8)).combined!
    }

    static func openIndex(_ envelope: VaultEnvelope, key: SymmetricKey) throws -> [MediaItem] {
        guard envelope.version == 1 else { throw PTError.message("此加密库版本不受支持") }
        do {
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.index), using: key, authenticating: Data(envelope.id.utf8))
            return try JSONDecoder().decode([MediaItem].self, from: clear)
        } catch { throw PTError.message("密码不正确，或加密索引已损坏。原文件未改动。") }
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Each chunk authenticates its identity, position and final flag; truncation/reordering fails closed.
    static func encrypt(source: URL, destination: URL, key: SymmetricKey, identity: String) throws -> (Int64, String) {
        let input = try FileHandle(forReadingFrom: source)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        try output.write(contentsOf: magic)
        var next = try input.read(upToCount: chunkSize) ?? Data()
        var index = 0
        var bytes: Int64 = 0
        var digest = SHA256()
        repeat {
            let current = next
            next = try input.read(upToCount: chunkSize) ?? Data()
            let last = next.isEmpty
            let aad = Data("\(identity):\(index):\(last ? 1 : 0)".utf8)
            let sealed = try AES.GCM.seal(current, using: key, authenticating: aad).combined!
            var length = UInt32(sealed.count).bigEndian
            try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try output.write(contentsOf: Data([last ? 1 : 0]))
            try output.write(contentsOf: sealed)
            digest.update(data: current)
            bytes += Int64(current.count)
            index += 1
        } while !next.isEmpty
        try output.synchronize()
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func decrypt(source: URL, destination: URL, key: SymmetricKey, identity: String, expectedBytes: Int64, expectedHash: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let output = try FileHandle(forWritingTo: destination)
        var success = false
        defer { try? input.close(); try? output.close(); if !success { try? FileManager.default.removeItem(at: destination) } }
        guard try input.read(upToCount: magic.count) == magic else { throw PTError.message("加密文件头无效") }
        var index = 0
        var total: Int64 = 0
        var digest = SHA256()
        while true {
            guard let lengthData = try input.read(upToCount: 4), lengthData.count == 4,
                  let flag = try input.read(upToCount: 1)?.first, flag <= 1 else { throw PTError.message("加密文件不完整") }
            let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 28, length <= UInt32(chunkSize + 28),
                  let sealed = try input.read(upToCount: Int(length)), sealed.count == Int(length) else { throw PTError.message("加密数据块已损坏") }
            let aad = Data("\(identity):\(index):\(flag)".utf8)
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
            try output.write(contentsOf: clear)
            digest.update(data: clear)
            total += Int64(clear.count)
            index += 1
            if flag == 1 {
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw PTError.message("加密文件存在异常尾部") }
                break
            }
        }
        let actualHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == expectedBytes, actualHash == expectedHash else { throw PTError.message("完整性校验失败") }
        try output.synchronize()
        success = true
    }
}
