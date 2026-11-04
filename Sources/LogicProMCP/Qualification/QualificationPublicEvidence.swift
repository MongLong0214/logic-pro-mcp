import CryptoKit
import Foundation

/// A signed public projection of the existing accepted private bundle. It shares
/// the operator's existing trust key; it contains no raw requests or readbacks.
enum QualificationPublicEvidence {
    static let filename = "qualification-public.json"
    static let schema = "qualification-public-evidence/v1"
    static let artifactNames = ["LogicProMCP", "LogicProMCP-macOS-universal.tar.gz", "LogicProMCP-macOS-arm64.tar.gz"]
    private static let domain = Data("logic-pro-mcp/qualification-public-evidence/v1\n".utf8)

    struct Artifact: Codable, Equatable {
        let name: String
        let sha256: String
    }
    struct Case: Codable, Equatable {
        let caseIDHash: String
        let operationID: String?
        let status: QualificationStatus
        let verificationKind: QualificationVerificationKind
        let liveCredited: Bool
    }
    struct Waiver: Codable, Equatable {
        let caseIDHash: String
        let reasonCode: String
        let owningIssue: String
        let capabilityHash: String
        let userImpactHash: String
        let affectsDefaultProfile: Bool
        let expiryVersion: String
    }
    struct Evidence: Codable, Equatable {
        let pathHash: String
        let sha256: String
        let caseIDHash: String
        let kind: String
    }
    struct Payload: Codable, Equatable {
        let schema: String
        let commitSHA: String
        let releaseVersion: String
        let binarySHA256: String
        let logicVersion: String
        let axis: QualificationAxis
        let runIDHash: String
        let startedAt: Double
        let completedAt: Double
        let privateManifestSHA256: String
        let artifacts: [Artifact]
        let cases: [Case]
        let waivers: [Waiver]
        let evidence: [Evidence]
        let total: Int
        let passed: Int
        let failed: Int
        let waived: Int
        let disclosure: String

        func isConsistent() -> Bool {
            schema == QualificationPublicEvidence.schema
                && artifacts.count == artifactNames.count
                && Set(artifacts.map(\.name)) == Set(artifactNames)
                && artifacts.allSatisfy { Self.isDigest($0.sha256) }
                && artifacts.first(where: { $0.name == "LogicProMCP" })?.sha256 == binarySHA256
                && Self.isDigest(binarySHA256) && Self.isDigest(privateManifestSHA256) && Self.isDigest(runIDHash)
                && !cases.isEmpty && Set(cases.map(\.caseIDHash)).count == cases.count
                && cases.allSatisfy { Self.isDigest($0.caseIDHash) }
                && total == cases.count && passed == cases.filter { $0.status == .passed }.count
                && failed == 0 && !cases.contains(where: { $0.status == .failed })
                && waived == cases.filter { $0.status == .waived }.count
                && !evidence.isEmpty && Set(evidence.map(\.pathHash)).count == evidence.count
                && evidence.allSatisfy { Self.isDigest($0.pathHash) && Self.isDigest($0.sha256) && Self.isDigest($0.caseIDHash) }
                && waivers.allSatisfy { Self.isDigest($0.caseIDHash) && Self.isDigest($0.userImpactHash) && Self.isDigest($0.capabilityHash) }
                && startedAt.isFinite && completedAt.isFinite && completedAt >= startedAt
        }
        private static func isDigest(_ text: String) -> Bool {
            text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
    private struct Envelope: Codable {
        let schema: String
        let payload: Data
        let signature: QualificationProvenanceSignature
    }
    enum Rejection: Error { case invalid }

    static func sign(_ payload: Payload, key: Curve25519.Signing.PrivateKey) throws -> Data {
        guard payload.isConsistent() else { throw Rejection.invalid }
        let data = try encode(payload)
        let signature = QualificationProvenanceSignature(algorithm: "ed25519",
            keyID: SupportBundleBuilder.sha256(key.publicKey.rawRepresentation),
            value: try key.signature(for: domain + data).base64EncodedString())
        return try encode(Envelope(schema: schema, payload: data, signature: signature))
    }

    static func verify(_ data: Data, trustedKey: Data) throws -> Payload {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: trustedKey)
        guard envelope.schema == schema, envelope.signature.algorithm == "ed25519",
              envelope.signature.keyID == SupportBundleBuilder.sha256(trustedKey),
              let signature = Data(base64Encoded: envelope.signature.value),
              key.isValidSignature(signature, for: domain + envelope.payload) else { throw Rejection.invalid }
        let payload = try JSONDecoder().decode(Payload.self, from: envelope.payload)
        guard payload.isConsistent() else { throw Rejection.invalid }
        return payload
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Parse a private snapshot, never scripts or helpers carried by a bundle.
    /// No archive member is extracted to the filesystem or executed.
    static let archiveCheck = #"""
import bisect, hashlib, pathlib, sys, tarfile, unicodedata
try:
    count, total, found, names = 0, 0, 0, set()
    with tarfile.open(sys.argv[1], 'r:gz') as archive:
        for member in archive:
            count += 1
            path = pathlib.PurePosixPath(member.name)
            name = unicodedata.normalize('NFD', unicodedata.normalize('NFD', str(path)).casefold())
            if (count > 10000 or not path.parts or path.is_absolute() or '..' in path.parts
                    or '\\' in member.name or member.name != str(path)
                    or name in names or not member.isfile() or member.size > 256 * 1024 * 1024):
                raise ValueError()
            total += member.size
            if total > 1024 * 1024 * 1024:
                raise ValueError()
            names.add(name)
            if member.name == 'LogicProMCP':
                if not member.mode & 0o111:
                    raise ValueError()
                found += 1
                digest = hashlib.sha256()
                with archive.extractfile(member) as source:
                    while True:
                        chunk = source.read(65536)
                        if not chunk:
                            break
                        digest.update(chunk)
                if digest.hexdigest() != sys.argv[2]:
                    raise ValueError()
    ordered = sorted(names)
    for name in names:
        prefix = name + '/'
        index = bisect.bisect_left(ordered, prefix)
        if index < len(ordered) and ordered[index].startswith(prefix):
            raise ValueError()
    if found != 1:
        raise ValueError()
except Exception:
    sys.exit(1)
print('ok')
"""#
}
