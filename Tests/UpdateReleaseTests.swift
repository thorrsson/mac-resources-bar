import CryptoKit
import Foundation

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@discardableResult
func run(_ arguments: [String], env: [String: String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.environment = env
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

// Ephemeral keys never enter the Keychain or a file.
let key = Curve25519.Signing.PrivateKey()
var env = ProcessInfo.processInfo.environment
env.removeValue(forKey: "SPARKLE_PRIVATE_ED_KEY")
env["SPARKLE_PUBLIC_ED_KEY"] = "invalid"
require(try run(["swift", "Scripts/validate-sparkle-keys.swift"], env: env) != 0,
        "Malformed public keys must fail")
env["SPARKLE_PUBLIC_ED_KEY"] = key.publicKey.rawRepresentation.base64EncodedString()
env["REQUIRE_SPARKLE"] = "1"
require(try run(["bash", "Scripts/release.sh", "0.0.0"], env: env) != 0,
        "Required update signing must fail without a private key")
env["SPARKLE_PRIVATE_ED_KEY"] = Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
require(try run(["swift", "Scripts/validate-sparkle-keys.swift"], env: env) != 0,
        "Mismatched signing keys must fail")
env["SPARKLE_PRIVATE_ED_KEY"] = key.rawRepresentation.base64EncodedString()
env["SIGNING_IDENTITY"] = "-"
env["REQUIRE_NOTARIZATION"] = "0"
env["BUILD_NUMBER"] = "999999"
env.removeValue(forKey: "NOTARY_PROFILE")
env.removeValue(forKey: "NOTARY_API_KEY_ID")
env.removeValue(forKey: "NOTARY_API_ISSUER_ID")
env.removeValue(forKey: "NOTARY_API_KEY_P8")
require(try run(["bash", "Scripts/release.sh", "0.0.0"], env: env) == 0,
        "Update release packaging must succeed")

let app = URL(fileURLWithPath: "build/ResourcesBar.app")
let plist = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
    format: nil
) as! [String: Any]
require(plist["SUPublicEDKey"] as? String == env["SPARKLE_PUBLIC_ED_KEY"], "Public key must be embedded")
require(plist["CFBundleVersion"] as? String == "999999", "Build number must be embedded")
require(plist["SUEnableAutomaticChecks"] as? Bool == true, "Automatic checks must default on")
require(plist["SUAutomaticallyUpdate"] as? Bool == false, "Silent installation must default off")
require(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true, "Archives must be verified before extraction")
require(try run(["codesign", "--verify", "--deep", "--strict", app.path], env: env) == 0,
        "Nested signatures must be valid")

let feed = try XMLDocument(contentsOf: URL(fileURLWithPath: "dist/appcast.xml"))
let items = try feed.nodes(forXPath: "/rss/channel/item")
require(items.count == 1, "Feed must contain only the current release")
let item = items[0] as! XMLElement
let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
require(item.elements(forLocalName: "version", uri: namespace).first?.stringValue == "999999",
        "Appcast build number must match app")
require(item.elements(forLocalName: "shortVersionString", uri: namespace).first?.stringValue == "0.0.0",
        "Appcast display version must match app")
let enclosure = item.elements(forName: "enclosure").first!
require(enclosure.attribute(forName: "url")?.stringValue ==
        "https://github.com/thorrsson/mac-resources-bar/releases/download/v0.0.0/ResourcesBar-0.0.0.dmg",
        "Download must use an immutable versioned release URL")
let archive = try Data(contentsOf: URL(fileURLWithPath: "dist/ResourcesBar-0.0.0.dmg"))
require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count),
        "Enclosure length must match the final DMG")
let signature = Data(base64Encoded: enclosure.attribute(forLocalName: "edSignature", uri: namespace)!.stringValue!)!
require(key.publicKey.isValidSignature(signature, for: archive), "DMG Ed25519 signature must verify")
print("Sparkle release packaging and signature checks passed.")
