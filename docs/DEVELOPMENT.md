# Development

Checks: `./scripts/ci-check.sh` runs everything CI runs. Releases are made by
pushing a `vX.Y.Z` tag that matches the version file; the release workflow
builds, signs and publishes. The OpenWrt feed and package signing are in
[OPENWRT25.md](OPENWRT25.md).

## Signed client release list

The desktop clients (Waypoint for macOS and Windows) update themselves. They
install a downloaded installer only if its SHA-256 appears in a list signed
with the client release key. This key is separate from the OpenWrt package
signing key (`keys/nikitid-openwrt-release.pem`); neither can sign for the
other.

### What a release publishes

Next to the installers, the release carries two files:

- `Waypoint-SHA256SUMS` - one line per installer, `<sha256 hex>  <file name>`
  (two spaces, lowercase hex, bare file names, no paths, sorted bytewise by
  name, LF line ends). It covers `Waypoint-*.pkg`, `*.msi` and `*.exe`.
  The router package list `SHA256SUMS` is a different file and is not signed
  by this key.
- `Waypoint-SHA256SUMS.sig` - the signature, a binary file.

### Signature format (the contract for both clients)

| part | value |
| --- | --- |
| algorithm | ECDSA, curve P-256 (prime256v1, secp256r1) |
| digest | SHA-256 of the exact bytes of `Waypoint-SHA256SUMS`, no normalisation |
| signature | DER `ECDSA-Sig-Value` (`SEQUENCE { r INTEGER, s INTEGER }`, RFC 3279), the file's raw bytes, no base64 |
| public key | SubjectPublicKeyInfo PEM, `keys/waypoint-client-release.pem`, embedded in each client at build time |

Verification in the clients, with no third-party libraries:

- Swift: `try P256.Signing.PublicKey(pemRepresentation: pem)` and
  `key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sig), for: listData)`
  (CryptoKit hashes `listData` with SHA-256 itself).
- .NET: `var key = ECDsa.Create(); key.ImportFromPem(pem);`
  `key.VerifyData(listBytes, sig, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)`.

A client then looks up the downloaded installer's name in the verified list and
compares the SHA-256 of the file. Any failure - missing signature, signature
that does not verify, name not listed, digest differs - installs nothing. The
key is rotated only by a new client version that carries the new public key.

The same format is produced and checked by `scripts/client-release-sign.sh`
(openssl and a SHA-256 tool only, runs on macOS and Linux):

```sh
scripts/client-release-sign.sh keygen private.pem public.pem
scripts/client-release-sign.sh list dist/Waypoint-* > Waypoint-SHA256SUMS
scripts/client-release-sign.sh sign Waypoint-SHA256SUMS private.pem Waypoint-SHA256SUMS.sig
scripts/client-release-sign.sh verify Waypoint-SHA256SUMS Waypoint-SHA256SUMS.sig keys/waypoint-client-release.pem dist
```

`scripts/test-client-release-sign.sh` signs a sample list with a throwaway key
and checks that a changed list, a changed or truncated signature, another key,
a changed installer and a non-P-256 key are all refused.

### Workflow

- `release` checks before it builds anything that the secret
  `CLIENT_RELEASE_SIGNING_KEY` is set, that `keys/waypoint-client-release.pem`
  exists and that the two match (a probe is signed and verified). A release
  without them fails before publishing.
- `sign-clients` runs after both client jobs succeed, downloads their
  installers from the release, writes and signs `Waypoint-SHA256SUMS`,
  verifies it against the committed public key and the downloaded files, and
  only then uploads both files. Without the secret it fails; it never uploads
  an unsigned list.

### One-time setup

1. Generate the pair on a trusted machine, outside the repository:
   `scripts/client-release-sign.sh keygen ~/waypoint-client.pem ~/waypoint-client.pub`.
2. Store the contents of the private key file as the repository Actions secret
   `CLIENT_RELEASE_SIGNING_KEY`, keep an offline backup, and delete the local
   copy. Losing it means a client release that existing clients cannot verify.
3. Copy the public key to `keys/waypoint-client-release.pem` and commit it.
   Embed the same file in the macOS and Windows clients.
