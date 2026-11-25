import CryptoKit
import XCTest
import GoLensFoundation

final class LinuxRuntimePackageTests: XCTestCase {
    private func manifest(version: String = "2026.11.23", minimumAppVersion: String = "1.0.0", agentProtocol: Int = 1) -> LinuxRuntimeManifest {
        LinuxRuntimeManifest(version: version, arch: "arm64", archive: "golens-linux-runtime-\(version)-arm64.tar.gz", archiveSize: 10, installedSize: 20, sha256: "00", minimumAppVersion: minimumAppVersion, agentProtocol: agentProtocol, components: ["kernel": "6.12.1"])
    }

    func testManifestRoundTripsThroughJSON() throws {
        let original = manifest()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(LinuxRuntimeManifest.decode(data), original)
        XCTAssertNil(LinuxRuntimeManifest.decode(Data("{\"version\": 1}".utf8)))
    }

    func testVersionsCompareNumerically() {
        XCTAssertEqual(LinuxRuntimeVersion.compare("2026.11.23", "2026.11.23.1"), .orderedAscending)
        XCTAssertEqual(LinuxRuntimeVersion.compare("2026.12.1", "2026.11.30"), .orderedDescending)
        XCTAssertEqual(LinuxRuntimeVersion.compare("1.0", "1.0.0"), .orderedSame)
    }

    func testSignatureMustMatchTheExactManifestBytesAndATrustedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let bytes = Data("{\"version\":\"2026.11.23\"}".utf8)
        let signature = try key.signature(for: bytes).base64EncodedString()
        let trusted = [key.publicKey.rawRepresentation.base64EncodedString()]
        XCTAssertTrue(LinuxRuntimeVerification.isSignatureValid(manifest: bytes, signatureBase64: signature + "\n", publicKeysBase64: trusted))
        var tampered = bytes
        tampered[tampered.startIndex] = UInt8(ascii: "[")
        XCTAssertFalse(LinuxRuntimeVerification.isSignatureValid(manifest: tampered, signatureBase64: signature, publicKeysBase64: trusted))
        XCTAssertFalse(LinuxRuntimeVerification.isSignatureValid(manifest: bytes, signatureBase64: signature, publicKeysBase64: [other.publicKey.rawRepresentation.base64EncodedString()]))
        XCTAssertFalse(LinuxRuntimeVerification.isSignatureValid(manifest: bytes, signatureBase64: "not base64", publicKeysBase64: trusted))
    }

    func testSHA256OfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(LinuxRuntimeVerification.sha256Hex(ofFileAt: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNil(LinuxRuntimeVerification.sha256Hex(ofFileAt: url.appendingPathExtension("missing")))
    }

    func testAvailability() {
        let available = manifest(version: "2026.12.1")
        XCTAssertEqual(LinuxRuntimeAvailability.resolve(installed: nil, available: available, appVersion: "1.0.0", agentProtocol: 1), .notInstalled(available))
        XCTAssertEqual(LinuxRuntimeAvailability.resolve(installed: manifest(), available: available, appVersion: "1.0.0", agentProtocol: 1), .updateAvailable(available))
        XCTAssertEqual(LinuxRuntimeAvailability.resolve(installed: available, available: available, appVersion: "1.0.0", agentProtocol: 1), .upToDate)
        let needsNewApp = manifest(version: "2026.12.1", minimumAppVersion: "2.0")
        XCTAssertEqual(LinuxRuntimeAvailability.resolve(installed: nil, available: needsNewApp, appVersion: "1.0.0", agentProtocol: 1), .requiresNewerApp(needsNewApp))
        XCTAssertEqual(LinuxRuntimeAvailability.resolve(installed: manifest(), available: needsNewApp, appVersion: "1.0.0", agentProtocol: 1), .upToDate)
        XCTAssertEqual(LinuxRuntimeAvailability.resolve(installed: manifest(agentProtocol: 0), available: manifest(), appVersion: "1.0.0", agentProtocol: 1), .installedNeedsUpdate)
        XCTAssertEqual(LinuxRuntimeAvailability.resolve(installed: manifest(agentProtocol: 0), available: available, appVersion: "1.0.0", agentProtocol: 1), .updateAvailable(available))
    }
}
