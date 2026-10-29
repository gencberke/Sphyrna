import CryptoKit
import Foundation

/// Invocation-local mutual authentication. The capability itself never crosses
/// the socket; the TUI contributes a fresh nonce and each direction has a
/// separate domain. This is in addition to the kernel TUI-peer witness.
enum OpenCodeTUIAuthentication {
    static func validNonce(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func proof(role: String, token: String, nonce: String, generation: Int64,
                      appSessionID: UUID, runID: UUID, instanceID: UUID) -> String {
        let message = ["sphyrna.opencode.tui.v1", role, nonce, appSessionID.uuidString,
                       runID.uuidString, instanceID.uuidString, String(generation)].joined(separator: "\n")
        let key = SymmetricKey(data: Data(token.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
    }
}
