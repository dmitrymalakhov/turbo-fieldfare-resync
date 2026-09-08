#if os(macOS)
import Foundation
import Security

/// Only classifies self-signatures for display/selection. TLS chain validation is
/// still performed by Security (suggestions) and Python/OpenSSL (Exchange).
enum AppMCPCertificateSignature {
    static func isSelfSigned(_ certificate: SecCertificate, der: Data) -> Bool {
        guard let key = SecCertificateCopyKey(certificate) else { return false }
        var input = DERReader(bytes: Array(der))
        guard let outer = input.read(tag: 0x30), input.isAtEnd else { return false }
        var body = DERReader(bytes: outer.value)
        guard let tbs = body.read(tag: 0x30), let algorithm = body.read(tag: 0x30),
              let signature = body.read(tag: 0x03), body.isAtEnd, signature.value.first == 0 else { return false }
        var identifier = DERReader(bytes: algorithm.value)
        guard let oid = identifier.read(tag: 0x06), let algorithm = algorithms[oid.value] else { return false }
        guard SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        return SecKeyVerifySignature(key, algorithm, Data(tbs.encoded) as CFData,
                                     Data(signature.value.dropFirst()) as CFData, nil)
    }

    // Unsupported signature algorithms remain visibly "Self-issued"; never guess.
    private static let algorithms: [[UInt8]: SecKeyAlgorithm] = [
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 5]: .rsaSignatureMessagePKCS1v15SHA1,
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 14]: .rsaSignatureMessagePKCS1v15SHA224,
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]: .rsaSignatureMessagePKCS1v15SHA256,
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 12]: .rsaSignatureMessagePKCS1v15SHA384,
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 13]: .rsaSignatureMessagePKCS1v15SHA512,
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 1]: .ecdsaSignatureMessageX962SHA1,
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 1]: .ecdsaSignatureMessageX962SHA224,
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 2]: .ecdsaSignatureMessageX962SHA256,
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 3]: .ecdsaSignatureMessageX962SHA384,
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 4]: .ecdsaSignatureMessageX962SHA512,
    ]

    private struct DERReader {
        let bytes: [UInt8]
        var offset = 0
        var isAtEnd: Bool { offset == bytes.count }
        mutating func read(tag: UInt8) -> (encoded: [UInt8], value: [UInt8])? {
            let start = offset
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
            offset += 1
            let first = Int(bytes[offset]); offset += 1
            var length = first
            if first & 0x80 != 0 {
                let count = first & 0x7f
                guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            }
            guard length <= bytes.count - offset else { return nil }
            let value = Array(bytes[offset..<(offset + length)]); offset += length
            return (Array(bytes[start..<offset]), value)
        }
    }
}
#endif
