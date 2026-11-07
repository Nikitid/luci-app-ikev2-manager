# Shared APK release key

`ikev2-manager-release.pem` is the legacy filename and
`nikitid-openwrt-release.pem` is its generic alias. The files are
byte-for-byte identical and contain the shared public P-256 key used for
Nikitid OpenWrt 25.12 APK packages and `packages.adb` indexes.

Public-key file SHA-256:

```text
f27474d9261f1084350cf4ba34ecdff29e533769c36483d8dd85566e30a6a703
```

The matching private key is not stored in this repository. Release builds read
it from the `OPENWRT_APK_SIGNING_KEY` GitHub Actions secret. Losing that key
requires an explicit key-rotation bootstrap on every installed router; exposing
it allows an attacker to publish trusted packages for every application in the
shared feed.

# Client release key

`waypoint-client-release.pem` (added by the maintainer, see
`docs/DEVELOPMENT.md`) is the public P-256 key that signs the desktop client
release list. It is unrelated to the APK key above. The private key lives only
in the `CLIENT_RELEASE_SIGNING_KEY` GitHub Actions secret.
