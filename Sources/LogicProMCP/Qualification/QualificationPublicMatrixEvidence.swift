import CryptoKit
import Foundation

/// A signed public projection of a complete, already-accepted private
/// qualification matrix. Child paths stay private; their exact attestation
/// bytes and the exact signed private root remain digest-bound here.
enum QualificationPublicMatrixEvidence {
    static let schema = "qualification-public-matrix/v1"
    private static let domain = Data("logic-pro-mcp/qualification-public-matrix/v1\n".utf8)

    struct Run: Codable, Equatable {
        let axis: QualificationAxis
        let childAttestationSHA256: String
        let payload: QualificationPublicEvidence.Payload
    }

    struct Payload: Codable, Equatable {
        let schema: String
        let commitSHA: String
        let releaseVersion: String
        let binarySHA256: String
        let logicVersion: String
        let operationCatalogSHA256: String
        let privateMatrixSHA256: String
        let artifacts: [QualificationPublicEvidence.Artifact]
        let runs: [Run]
        let disclosure: String

        func isConsistent() -> Bool {
            guard schema == QualificationPublicMatrixEvidence.schema,
                  Self.isCommitSHA(commitSHA),
                  !releaseVersion.isEmpty,
                  !logicVersion.isEmpty,
                  !disclosure.isEmpty,
                  Self.isDigest(binarySHA256),
                  Self.isDigest(operationCatalogSHA256),
                  Self.isDigest(privateMatrixSHA256),
                  artifacts.count == QualificationPublicEvidence.artifactNames.count,
                  artifacts.map(\.name) == QualificationPublicEvidence.artifactNames,
                  artifacts.allSatisfy({ Self.isDigest($0.sha256) }),
                  artifacts.first(where: { $0.name == "LogicProMCP" })?.sha256 == binarySHA256,
                  let first = runs.first else {
                return false
            }
            let expectedAxes = Set(QualificationAxis.requiredAxes(
                profile: first.axis.profile,
                cache: first.axis.cache,
                fixture: first.axis.fixture
            ))
            return runs.map(\.axis) == runs.map(\.axis).sorted { $0.key < $1.key }
                && runs.count == expectedAxes.count
                && Set(runs.map(\.axis)) == expectedAxes
                && Set(runs.map(\.childAttestationSHA256)).count == runs.count
                && runs.allSatisfy { run in
                    Self.isDigest(run.childAttestationSHA256)
                        && run.axis == run.payload.axis
                        && run.payload.isConsistent()
                        && run.payload.commitSHA == commitSHA
                        && run.payload.releaseVersion == releaseVersion
                        && run.payload.binarySHA256 == binarySHA256
                        && run.payload.logicVersion == logicVersion
                        && run.payload.artifacts == artifacts
                }
                && Set(runs.map(\.payload.runIDHash)).count == runs.count
        }

        private static func isDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }

        private static func isCommitSHA(_ value: String) -> Bool {
            value.utf8.count == 40 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
    }

    private struct Envelope: Codable {
        let schema: String
        let payload: Data
        let signature: QualificationProvenanceSignature
    }

    enum Rejection: Error {
        case invalid
    }

    static func sign(
        _ payload: Payload,
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        guard payload.isConsistent() else { throw Rejection.invalid }
        let data = try QualificationPublicEvidence.encode(payload)
        let signature = QualificationProvenanceSignature(
            algorithm: "ed25519",
            keyID: SupportBundleBuilder.sha256(key.publicKey.rawRepresentation),
            value: try key.signature(for: domain + data).base64EncodedString()
        )
        return try QualificationPublicEvidence.encode(Envelope(
            schema: schema,
            payload: data,
            signature: signature
        ))
    }

    static func verify(_ data: Data, trustedKey: Data) throws -> Payload {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: trustedKey)
        guard envelope.schema == schema,
              envelope.signature.algorithm == "ed25519",
              envelope.signature.keyID == SupportBundleBuilder.sha256(trustedKey),
              let signature = Data(base64Encoded: envelope.signature.value),
              key.isValidSignature(signature, for: domain + envelope.payload) else {
            throw Rejection.invalid
        }
        let payload = try JSONDecoder().decode(Payload.self, from: envelope.payload)
        guard payload.isConsistent() else { throw Rejection.invalid }
        return payload
    }
}
