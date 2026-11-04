# Public qualification evidence

`trusted-verifier export-public-matrix` derives `qualification-public.json` from an
accepted signed private qualification matrix and the final executable plus both existing
release archives. It reuses the operator's existing qualification signing key.
The private matrix and public directory must be separate, without either
containing the other. An existing public evidence file is never overwritten.

The public file authenticates source/version/all required axes, the executable and archive
digests, archive executable membership, case dispositions, waiver metadata and
every signed child attestation digest plus the exact private matrix root. Raw requests/readbacks, filesystem
paths, case/run identifiers and waiver impact text remain private. Their hashes
retain the binding. Waived cases do not become positively qualified operations.

The trusted operator prepares a fresh public directory from the final candidate,
then exports and verifies the public representation:

```sh
bash Scripts/release-consume-final.sh stage "$VERSION" "$COMMIT" \
  "$CANDIDATE" "$PRIVATE_MATRIX" "$TRUSTED_VERIFIER" "$PUBLIC_DIRECTORY"
"$TRUSTED_VERIFIER" export-public-matrix --candidate "$CANDIDATE" \
  --matrix-index "$PRIVATE_MATRIX/qualification-matrix-input.json" \
  --public-directory "$PUBLIC_DIRECTORY" \
  --release-version "$VERSION" --expected-commit "$COMMIT"
bash Scripts/release-consume-final.sh verify-public "$VERSION" "$COMMIT" \
  "$CANDIDATE" "$PRIVATE_MATRIX" "$TRUSTED_VERIFIER" "$PUBLIC_DIRECTORY"
```

Export requires `LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY`, as the existing trusted
signing command does. Signing material is not supplied by the candidate/matrix
and is not forwarded to the isolated archive parser. Export itself does not
upload files or activate a release. The normal release source-member/install
checks remain necessary; export's archive check establishes the executable
member and safe regular-member structure, rather than source equality for every
companion file.

For the existing owner-staged release workflow, make a ZIP containing only these
six public files at its root:

```sh
(cd "$PUBLIC_DIRECTORY" && zip "$PUBLIC_ASSETS_ZIP" \
  LogicProMCP LogicProMCP-macOS-universal.tar.gz LogicProMCP-macOS-arm64.tar.gz \
  RELEASE-METADATA.json SHA256SUMS.txt qualification-public.json)
```

Use an absolute output ZIP path. Supply its protected HTTPS location and SHA-256
through `QUALIFICATION_PUBLIC_ASSETS_URL` and
`QUALIFICATION_PUBLIC_ASSETS_SHA256`, alongside the existing candidate/private
evidence inputs and separately trusted public key. Hosted jobs receive no signing
key. They consume these exact archives without repackaging, verify the public
signature against the accepted private matrix root and every required axis, and derive metadata
from the accepted executable. Missing, changed or mismatched evidence stops
publication. Install validation still runs before publication.

The release uploads `qualification-public.json` with the executable and archives.
The post-publication job retrieves it and the other public assets without an
authentication header and compares their bytes with the verified build artifact.
An actual successful release and unauthenticated retrieval are required before
claiming that public publication succeeded.

An external consumer retrieves the public evidence file, `LogicProMCP` and both
archives, then runs an independently trusted verifier build:

```sh
LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY="$AUTHENTICATED_PUBLIC_KEY" \
  "$TRUSTED_VERIFIER" verify-public-matrix --public-directory "$DOWNLOADED_FILES" \
  --release-version "$VERSION" --expected-commit "$COMMIT"
```

The key comes from an independently authenticated channel, not those downloaded
files. A successful command prints authenticated metadata and verifies the
actual public file digests. It does not replay private semantic evidence.
Changing a file and its neighboring checksum cannot replace the signature.
This provides authenticity and tamper detection under the trusted signer/key
assumption, rather than storage immutability. Public key distribution still
requires an independently authenticated channel.
