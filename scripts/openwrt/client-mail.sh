#!/bin/sh
# Mail settings and the message handed to the mail tool, on an installed
# OpenWrt userland. The tool itself is replaced by a recorder: what this
# proves is the store, the refusals and what the tool is given, not delivery.
set -eu
mail=/usr/libexec/ikev2-manager.d/client-access-mail.uc
store=/etc/ikev2-manager/mail.json
work="$(mktemp -d)"
step=baseline
cleanup() {
 rc=$?
 [ "$rc" = 0 ] || printf 'client-mail: failed step=%s\n' "$step" >&2
 rm -f "$store" /usr/bin/msmtp
 rm -rf "$work"
 exit "$rc"
}
trap cleanup EXIT
mkdir -p /var/run/ikev2-client-admin && chmod 700 /var/run/ikev2-client-admin
rm -f "$store" /usr/bin/msmtp
[ "$(ucode "$mail" show | jsonfilter -e '@.configured')" = false ]
[ "$(ucode "$mail" show | jsonfilter -e '@.available')" = false ]
step=refusals
for bad in '"host":"smtp example.com","port":587,"security":"starttls","user":"u@example.com","password":"p","from":"u@example.com"' \
 '"host":"smtp.example.com","port":0,"security":"starttls","user":"u@example.com","password":"p","from":"u@example.com"' \
 '"host":"smtp.example.com","port":587,"security":"plain","user":"u@example.com","password":"p","from":"u@example.com"' \
 '"host":"smtp.example.com","port":587,"security":"starttls","user":"u@example.com","password":"p\"q","from":"u@example.com"' \
 '"host":"smtp.example.com","port":587,"security":"starttls","user":"u@example.com","password":"p","from":"not an address"'; do
 if printf '{"version":1,%s}' "$bad" | ucode "$mail" save 2>/dev/null; then exit 1; fi
done
[ ! -e "$store" ]
step=save
printf '{"version":1,"host":"smtp.example.com","port":465,"security":"ssl","user":"sender@example.com","password":"correct horse","from":"sender@example.com"}' | ucode "$mail" save
[ "$(ls -l "$store" | cut -c1-10)" = '-rw-------' ]
shown="$(ucode "$mail" show)"
[ "$(printf '%s' "$shown" | jsonfilter -e '@.has_password')" = true ]
! printf '%s' "$shown" | grep -q 'correct horse'
# An empty password field keeps the stored one.
printf '{"version":1,"host":"smtp.example.com","port":587,"security":"starttls","user":"sender@example.com","password":null,"from":"sender@example.com"}' | ucode "$mail" save
grep -q 'correct horse' "$store"
step=no-tool
if printf '{"version":1,"to":"person@example.com","subject":"s","body":"b"}' | ucode "$mail" send 1-1 2>/dev/null; then exit 1; fi
step=send
cat >/usr/bin/msmtp <<RECORD
#!/bin/sh
printf '%s\n' "\$*" >"$work/arguments"
for argument in "\$@"; do case "\$argument" in --file=*) cp "\${argument#--file=}" "$work/config" ;; esac; done
cat >"$work/message"
RECORD
chmod 755 /usr/bin/msmtp
[ "$(ucode "$mail" show | jsonfilter -e '@.available')" = true ]
link='https://vpn.example.com:8443/client/v1/enroll#cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
printf '{"version":1,"to":"person@example.com","subject":"Ссылка","body":"Paste this link:\\n%s\\n"}' "$link" | ucode "$mail" send 7-1
grep -q 'person@example.com' "$work/arguments"
! grep -q 'correct horse' "$work/arguments"
grep -q '^host smtp.example.com$' "$work/config" && grep -q '^port 587$' "$work/config" && grep -q '^tls_starttls on$' "$work/config"
grep -q '^password "correct horse"$' "$work/config"
[ ! -e /var/run/ikev2-client-admin/mail-7-1.conf ]
grep -q '^To: person@example.com' "$work/message"
grep -q '^Subject: =?UTF-8?B?' "$work/message"
sed '1,/^.$/d' "$work/message" | tr -d '\r\n' >"$work/encoded"
ucode -e 'import { readfile } from "fs"; print(b64dec(readfile(ARGV[0])));' "$work/encoded" >"$work/body"
grep -qF "$link" "$work/body"
step=refused-message
for bad in '"to":"two@example.com, other@example.com","subject":"s","body":"b"' '"to":"person@example.com","subject":"s\r\nBcc: x@example.com","body":"b"'; do
 if printf '{"version":1,%s}' "$bad" | ucode "$mail" send 7-2 2>/dev/null; then exit 1; fi
done
printf '%s\n' 'client-mail: private settings, kept password, refusals, a message with its link and no secret in arguments passed'
