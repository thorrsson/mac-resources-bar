import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

let env = ProcessInfo.processInfo.environment
guard let publicValue = env["SPARKLE_PUBLIC_ED_KEY"],
      let publicKey = Data(base64Encoded: publicValue), publicKey.count == 32 else {
    fail("SPARKLE_PUBLIC_ED_KEY must be a base64-encoded 32-byte Ed25519 public key.")
}
if let privateValue = env["SPARKLE_PRIVATE_ED_KEY"] {
    guard let seed = Data(base64Encoded: privateValue), seed.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("SPARKLE_PRIVATE_ED_KEY must be a 32-byte base64 seed exported by Sparkle 2.10 generate_keys.")
    }
    guard key.publicKey.rawRepresentation == publicKey else {
        fail("Sparkle public and private keys do not match.")
    }
}
