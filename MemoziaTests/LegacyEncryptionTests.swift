import CryptoKit
import Foundation
import Testing
@testable import Memozia

struct LegacyEncryptionTests {
    private enum LookupError: Error, Equatable { case denied }

    private func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        try #require(AES.GCM.seal(data, using: key).combined)
    }

    @Test func currentDataDoesNotReadLegacyKey() throws {
        let key = SymmetricKey(size: .bits256)
        let data = Data("Current Memozia data".utf8)
        let ciphertext = try seal(data, with: key)
        let result = try EncryptionService.openSealedData(ciphertext, using: key) {
            throw LookupError.denied
        }
        #expect(result == data)
    }

    @Test func legacyTextUsesLegacyKeyAfterPrimaryAuthenticationFails() throws {
        let current = SymmetricKey(size: .bits256)
        let legacy = SymmetricKey(size: .bits256)
        let data = Data("历史转写与总结 — compatibility fixture".utf8)
        let ciphertext = try seal(data, with: legacy)
        var reads = 0
        let result = try EncryptionService.openSealedData(ciphertext, using: current) {
            reads += 1
            return legacy
        }
        #expect(result == data)
        #expect(reads == 1)
    }

    @Test func legacyBinaryFilesRemainByteExact() throws {
        let current = SymmetricKey(size: .bits256)
        let legacy = SymmetricKey(size: .bits256)
        let data = Data((0..<256).map(UInt8.init))
        let ciphertext = try seal(data, with: legacy)
        let result = try EncryptionService.openSealedData(ciphertext, using: current) { legacy }
        #expect(result == data)
    }

    @Test func archivedMemoziaDataRemainsReadableAfterPrimaryKeySwitch() throws {
        let memonta = SymmetricKey(size: .bits256)
        let previousMemozia = SymmetricKey(size: .bits256)
        let data = Data("Data saved before switching the primary key".utf8)
        let ciphertext = try seal(data, with: previousMemozia)
        let result = try EncryptionService.openSealedData(
            ciphertext, using: memonta, previousKey: { previousMemozia }
        ) {
            throw LookupError.denied
        }
        #expect(result == data)
    }

    @Test func nonmatchingArchivedKeyDoesNotPreventLegacyRead() throws {
        let legacy = SymmetricKey(size: .bits256)
        let data = Data("Historical Memonta content".utf8)
        let ciphertext = try seal(data, with: legacy)
        let result = try EncryptionService.openSealedData(
            ciphertext, using: SymmetricKey(size: .bits256),
            previousKey: { SymmetricKey(size: .bits256) }, legacyKey: { legacy }
        )
        #expect(result == data)
    }

    @Test func missingLegacyKeyDoesNotTurnCiphertextIntoEmptyData() throws {
        let ciphertext = try seal(Data("old data".utf8), with: SymmetricKey(size: .bits256))
        #expect(throws: CryptoKitError.self) {
            try EncryptionService.openSealedData(ciphertext, using: SymmetricKey(size: .bits256)) { nil }
        }
    }

    @Test func legacyKeychainFailureIsPropagated() throws {
        let ciphertext = try seal(Data("old data".utf8), with: SymmetricKey(size: .bits256))
        #expect(throws: LookupError.denied) {
            try EncryptionService.openSealedData(ciphertext, using: SymmetricKey(size: .bits256)) {
                throw LookupError.denied
            }
        }
    }

    @Test func malformedCiphertextDoesNotReadLegacyKey() {
        var reads = 0
        #expect(throws: CryptoKitError.self) {
            try EncryptionService.openSealedData(Data([1, 2, 3]), using: SymmetricKey(size: .bits256)) {
                reads += 1
                return SymmetricKey(size: .bits256)
            }
        }
        #expect(reads == 0)
    }

    @Test func corruptedLegacyAuthenticationTagStillFails() throws {
        let legacy = SymmetricKey(size: .bits256)
        var ciphertext = try seal(Data("old data".utf8), with: legacy)
        ciphertext[ciphertext.count - 1] ^= 1
        #expect(throws: CryptoKitError.self) {
            try EncryptionService.openSealedData(ciphertext, using: SymmetricKey(size: .bits256)) { legacy }
        }
    }
}
