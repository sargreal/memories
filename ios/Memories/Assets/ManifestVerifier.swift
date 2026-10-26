import CryptoKit
import Foundation

/**
 * Verifies the DSSE envelope over the TUF JS asset targets before any URL
 * or hash from describeApi is trusted or executed. See
 * OtherController::describeApi (jsManifest) and the pinned public key in
 * webpack.manifest-sign-plugin.ts.
 */
enum ManifestVerifier {
    static let publicKey = "aA2fpqrrJHTiCkE9ecQNDR5V1qO7oHppjdJQ7Pj5nhQ="
    static let debugPublicKey = "MIJxGvOr0LMg9Isyfi5S4cHQsP+v4mFzrsmY2AYKOjs="
    private static let payloadType = "application/vnd.tuf+json"

    /**
     * True when the describe carries no manifest, or its DSSE envelope
     * verifies and its TUF targets are fresh.
     */
    static func verifyDescribe(_ describe: [String: Any]) -> Bool {
        guard let raw = describe["jsManifest"], !(raw is NSNull) else { return true }
        guard let envelope = raw as? [String: Any] else {
            log.error("Bad jsManifest encoding")
            return false
        }
        guard envelope["payloadType"] as? String == payloadType else {
            log.error("Unexpected DSSE payloadType")
            return false
        }
        guard let signatures = envelope["signatures"] as? [[String: Any]], signatures.count == 1 else {
            log.error("DSSE envelope must carry exactly one signature")
            return false
        }
        guard let payload = (envelope["payload"] as? String).flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }),
              let sig = (signatures[0]["sig"] as? String).flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }),
              sig.count == 64
        else {
            log.error("Bad DSSE payload or signature encoding")
            return false
        }

        #if DEBUG
        let keys = [publicKey, debugPublicKey]
        #else
        let keys = [publicKey]
        #endif
        let pae = preAuthEncoding(payload)
        let valid = keys.contains { b64 in
            guard let raw = Data(base64Encoded: b64),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: pae)
        }
        guard valid else {
            log.error("Manifest signature mismatch")
            return false
        }
        return targetsFresh(payload)
    }

    /** Decoded TUF targets ({name: {length, hashes, custom: {href}}}) of a verified describe. */
    static func targets(_ describe: [String: Any]) -> [String: Any]? {
        guard let payload = ((describe["jsManifest"] as? [String: Any])?["payload"] as? String).flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return json["targets"] as? [String: Any]
    }

    private static func targetsFresh(_ payload: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let expires = json["expires"] as? String
        else {
            log.error("Bad TUF targets encoding")
            return false
        }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: expires) ?? fractional.date(from: expires) else {
            log.error("Bad TUF targets expiry")
            return false
        }
        if Date() > date {
            log.error("TUF targets expired at \(expires)")
            return false
        }
        return true
    }

    /** DSSE pre-auth encoding: "DSSEv1" SP len(type) SP type SP len(payload) SP payload. */
    private static func preAuthEncoding(_ payload: Data) -> Data {
        let type = Data(payloadType.utf8)
        var out = Data("DSSEv1 \(type.count) ".utf8)
        out.append(type)
        out.append(Data(" \(payload.count) ".utf8))
        out.append(payload)
        return out
    }
}
