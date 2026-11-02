#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ssl/acme" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/bin"
cp "$root"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"

cat >"$tmp/bin/uci" <<EOF
#!/bin/sh
key=
for arg in "\$@"; do key="\$arg"; done
case "\$key" in
	ikev2-manager.server.enabled) echo 1 ;;
	ikev2-manager.server.identity) echo vpn.example.test ;;
	ikev2-manager.server.cert_source) echo "$tmp/root/etc/ssl/acme" ;;
	ikev2-manager.server.cert_file|ikev2-manager.server.key_file) ;;
	'acme.@acme[0].state_dir') echo "$tmp/root/etc/acme" ;;
esac
EOF
chmod 755 "$tmp/bin/uci"

cat >"$tmp/leaf.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = vpn.example.test
[v3]
subjectAltName = DNS:vpn.example.test
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
cat >"$tmp/ca.ext" <<'EOF'
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Test Root' \
	-addext 'subjectKeyIdentifier=hash' -addext 'authorityKeyIdentifier=keyid:always' \
	-keyout "$tmp/root.key" -out "$tmp/root.crt" >/dev/null 2>&1
# The intermediate deliberately has the same subject as its issuer but is
# signed with the root key. It is self-issued, not self-signed, and must stay
# in the served chain.
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=Test Root' \
	-keyout "$tmp/intermediate-one.key" -out "$tmp/intermediate-one.csr" >/dev/null 2>&1
openssl x509 -req -days 2 -in "$tmp/intermediate-one.csr" \
	-CA "$tmp/root.crt" -CAkey "$tmp/root.key" -CAcreateserial \
	-extfile "$tmp/ca.ext" -out "$tmp/intermediate-one.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -config "$tmp/leaf.cnf" \
	-keyout "$tmp/root/etc/ssl/acme/vpn.example.test.key" \
	-out "$tmp/leaf.csr" >/dev/null 2>&1
openssl x509 -req -days 2 -in "$tmp/leaf.csr" \
	-CA "$tmp/intermediate-one.crt" -CAkey "$tmp/intermediate-one.key" -CAcreateserial \
	-extfile "$tmp/leaf.cnf" -extensions v3 -out "$tmp/leaf.crt" >/dev/null 2>&1
cat "$tmp/leaf.crt" "$tmp/intermediate-one.crt" "$tmp/root.crt" \
	>"$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt"
cp "$tmp/root/etc/ssl/acme/vpn.example.test.key" "$tmp/leaf.key"

IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync

cmp "$tmp/leaf.crt" "$tmp/root/etc/swanctl/x509/ikev2.pem"
openssl x509 -in "$tmp/root/etc/swanctl/x509ca/ikev2-server-chain-1.pem" \
	-noout -subject | grep -q 'Test Root'
[ ! -e "$tmp/root/etc/swanctl/x509ca/ikev2-server-chain-2.pem" ]

cp -R "$tmp/root/etc/swanctl" "$tmp/swanctl.before"
cat "$tmp/leaf.crt" "$tmp/root.crt" "$tmp/intermediate-one.crt" \
	>"$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt"
if IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync \
		>/dev/null 2>&1; then
	printf 'misordered certificate chain unexpectedly succeeded\n' >&2
	exit 1
fi
diff -ru "$tmp/swanctl.before" "$tmp/root/etc/swanctl"
cat "$tmp/leaf.crt" "$tmp/intermediate-one.crt" "$tmp/root.crt" \
	>"$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
	-out "$tmp/root/etc/ssl/acme/vpn.example.test.key" >/dev/null 2>&1
if IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync \
		>/dev/null 2>&1; then
	printf 'mismatched certificate key unexpectedly succeeded\n' >&2
	exit 1
fi
diff -ru "$tmp/swanctl.before" "$tmp/root/etc/swanctl"

# A restore left copies where ACME keeps its links; ACME has since renewed
# into its own directory. The renewal is what the server must serve.
cp "$tmp/leaf.key" "$tmp/root/etc/ssl/acme/vpn.example.test.key"
acme="$tmp/root/etc/acme/vpn.example.test"
mkdir -p "$acme"
openssl req -new -newkey rsa:2048 -nodes -config "$tmp/leaf.cnf" \
	-keyout "$acme/vpn.example.test.key" -out "$tmp/renewed.csr" >/dev/null 2>&1
openssl x509 -req -days 2 -in "$tmp/renewed.csr" \
	-CA "$tmp/intermediate-one.crt" -CAkey "$tmp/intermediate-one.key" -CAcreateserial \
	-extfile "$tmp/leaf.cnf" -extensions v3 -out "$tmp/renewed.crt" >/dev/null 2>&1
cat "$tmp/renewed.crt" "$tmp/intermediate-one.crt" "$tmp/root.crt" >"$acme/fullchain.cer"

# An ACME pair that does not hold together is not taken over the copies.
cp "$acme/vpn.example.test.key" "$tmp/renewed.key"
cp "$tmp/leaf.key" "$acme/vpn.example.test.key"
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync >/dev/null
cmp -s "$tmp/leaf.key" "$tmp/root/etc/ssl/acme/vpn.example.test.key" || {
	printf 'a mismatched ACME pair replaced the restored key\n' >&2
	exit 1
}
cmp -s "$tmp/leaf.crt" "$tmp/root/etc/swanctl/x509/ikev2.pem" || {
	printf 'a mismatched ACME pair changed the served certificate\n' >&2
	exit 1
}

cp "$tmp/renewed.key" "$acme/vpn.example.test.key"
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync >/dev/null
cmp -s "$tmp/renewed.crt" "$tmp/root/etc/swanctl/x509/ikev2.pem" || {
	printf 'the server still serves the restored certificate after an ACME renewal\n' >&2
	exit 1
}
# Plain copies of ACME's pair, which the client API accepts; a link it refuses.
for file in vpn.example.test.fullchain.crt vpn.example.test.key; do
	[ -f "$tmp/root/etc/ssl/acme/$file" ] && [ ! -L "$tmp/root/etc/ssl/acme/$file" ] || {
		printf '%s is not a plain file, which the client API refuses\n' "$file" >&2
		exit 1
	}
done
cmp -s "$acme/fullchain.cer" "$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt" &&
	cmp -s "$acme/vpn.example.test.key" "$tmp/root/etc/ssl/acme/vpn.example.test.key" || {
	printf 'the source directory does not hold the renewed pair\n' >&2
	exit 1
}
# A link ACME left is turned into a copy as well.
rm "$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt"
ln -s "$acme/fullchain.cer" "$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt"
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-cert-sync >/dev/null
[ ! -L "$tmp/root/etc/ssl/acme/vpn.example.test.fullchain.crt" ] || {
	printf 'a link was left where the client API needs a file\n' >&2
	exit 1
}

printf 'server certificate chain tests OK\n'
