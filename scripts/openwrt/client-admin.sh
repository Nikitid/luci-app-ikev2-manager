#!/bin/sh
# Runs only in a disposable installed OpenWrt container, before API tests.
set -eu
work="$(mktemp -d)"
control=/usr/libexec/ikev2-manager.d/client-access-control.uc
state_dir=/etc/ikev2-manager/clients
service_dir=/etc/ikev2-manager/services.d
worker_pid=''
test_step=baseline
cleanup() {
 test_rc=$?
 [ "$test_rc" = 0 ] || printf "client-admin: failed step=%s\n" "$test_step" >&2
 [ -z "$worker_pid" ] || { kill "$worker_pid" 2>/dev/null || :; wait "$worker_pid" 2>/dev/null || :; }
 rm -rf "$work" "$state_dir"
 rm -f "$service_dir/test_service.lst"
 rm -rf /var/run/ikev2-client-seen
}
trap cleanup EXIT INT TERM
mkdir -p "$service_dir"
mkdir -m 700 "$state_dir"
ucode /src/scripts/openwrt/client-runtime-state.uc "$state_dir" seed
printf 'catalog.example.com\n' >"$service_dir/test_service.lst"
cat >"$work/request.json" <<'JSON'
{"version":1,"expected_generation":1,"operation":"configure-service","payload":{"id":"test_service","client_access":true,"transports":[{"protocol":"tcp","ports":[443]}]}}
JSON
ucode "$control" update <"$work/request.json" >"$work/result"
grep -qx 'generation=2' "$work/result"
cat >"$work/request.json" <<'JSON'
{"version":1,"expected_generation":2,"operation":"assign-device","payload":{"id":"alice","enabled":true,"selected_services":["test_service"]}}
JSON
ucode "$control" update <"$work/request.json" >"$work/result"
grep -qx 'generation=3' "$work/result"
ucode "$control" inspect >"$work/inspection"
! grep -q 'token_sha256\|previous_policy' "$work/inspection"
ucode -e 'import {readfile} from "fs"; let state=json(readfile(ARGV[0])); if(state.api.devices[0].policy.resources[0].domain!="catalog.example.com" || state.publication.devices[0].token_sha256!="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") die("Wrong assignment or credential changed");' "$state_dir/state.json"
printf 'catalog.example.com\nupdated.catalog.example.com\n' >"$service_dir/test_service.lst"
# Existing api is a compiled fixture rather than an actual catalog service.
# Disable its publication before refreshing the real marked catalog entry.
ucode -e 'import {read_client_state,publish_client_state} from "/usr/libexec/ikev2-manager.d/client-access-store.uc"; let state=read_client_state(ARGV[0]), desired=state.publication; delete desired.allocations; for(let device in desired.devices) delete device.previous_policy; desired.services[0].client_access=false; publish_client_state(ARGV[0],desired,state.generation,false);' "$state_dir"
ucode "$control" refresh >"$work/result"
grep -qx 'generation=5' "$work/result"
ucode -e 'import {readfile} from "fs"; let state=json(readfile(ARGV[0])); if(length(state.api.devices[0].policy.resources)!=2 || state.api.devices[0].policy.revision!=3) die("Central domain update not published");' "$state_dir/state.json"
ucode "$control" refresh >"$work/result"
grep -qx 'generation=5' "$work/result"
grep -qx 'changed=0' "$work/result"
before="$(sha256sum "$state_dir/state.json")"
if ucode "$control" update <"$work/request.json" >/dev/null 2>&1; then exit 1; fi
[ "$(sha256sum "$state_dir/state.json")" = "$before" ]
# A separate background worker must deliver catalog edits without a manual
# refresh and without running inside the admission loop.
cp /usr/libexec/ikev2-client-catalog "$work/catalog-worker.sh"
IKEV2_CLIENT_CATALOG_RUNTIME="$work/catalog-runtime" IKEV2_CLIENT_CATALOG_INTERVAL=1 IKEV2_CLIENT_CATALOG_RETRY=1 sh "$work/catalog-worker.sh" watch >"$work/catalog-worker.log" 2>&1 &
worker_pid=$!
printf 'catalog.example.com\nupdated.catalog.example.com\nbackground.catalog.example.com\n' >"$service_dir/test_service.lst"
i=0
until ucode "$control" status | grep -qx 'generation=6'; do
 i=$((i + 1)); [ "$i" -lt 15 ] || { cat "$work/catalog-worker.log" >&2; exit 1; }
 sleep 1
done
ucode -e 'import {readfile} from "fs"; let state=json(readfile(ARGV[0])); if(length(state.api.devices[0].policy.resources)!=3) die("Background domain update missing");' "$state_dir/state.json"
kill "$worker_pid"
wait "$worker_pid" 2>/dev/null || :
worker_pid=''
test_step=baseline
# Exercise the installed detached LuCI bridge and its one-shot inbox.
bridge=/usr/libexec/ikev2-client-admin
if [ "${CLIENT_ADMIN_INPUT_MUTATION:-0}" = 1 ]; then
 sed -i 's/ || info.mode != 0600//' /usr/libexec/ikev2-manager.d/client-access-input.uc
fi
token="admin-test-$$"
input="/var/run/ikev2-client-admin-$token.in"
cat >"$input" <<'JSON'
{"version":1,"expected_generation":6,"operation":"configure-service","payload":{"id":"test_service","client_access":false,"transports":[{"protocol":"tcp","ports":[443]}]}}
JSON
chmod 600 "$input"
"$bridge" client-admin-update "$token" >"$work/queued"
[ ! -e "$input" ]
job="$(sed -n 's/^action_id=//p' "$work/queued")"
[ -n "$job" ]
i=0
while :; do
 "$bridge" client-admin-status "$job" >"$work/job"
 grep -qx 'state=ok' "$work/job" && break
 ! grep -qx 'state=error' "$work/job" || { cat "$work/job" >&2; exit 1; }
 i=$((i + 1)); [ "$i" -lt 15 ] || exit 1
 sleep 1
done
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(s.generation!=7 || s.api.devices[0].enabled || length(s.publication.devices[0].selected_services)) die("Queued revocation failed");' "$state_dir/state.json"
IKEV2_RUNTIME_LIB_DIR=/tmp/untrusted "$bridge" client-admin-show >"$work/bridge-inspect"
! grep -q 'token_sha256\|previous_policy' "$work/bridge-inspect"
# A stale edit is a completed error job and does not mutate committed state.
before="$(sha256sum "$state_dir/state.json")"
token="admin-stale-$$"
input="/var/run/ikev2-client-admin-$token.in"
cp "$work/request.json" "$input"
chmod 600 "$input"
"$bridge" client-admin-update "$token" >"$work/queued"
job="$(sed -n 's/^action_id=//p' "$work/queued")"
i=0
until "$bridge" client-admin-status "$job" | grep -qx 'state=error'; do
 i=$((i + 1)); [ "$i" -lt 15 ] || exit 1
 sleep 1
done
[ "$(sha256sum "$state_dir/state.json")" = "$before" ]
# Test input metadata independently of the publication schema.
token="admin-unsafe-$$"
input="/var/run/ikev2-client-admin-$token.in"
cp "$work/request.json" "$input"
chmod 644 "$input"
if "$bridge" client-admin-update "$token" >/dev/null 2>&1; then echo 'unsafe input accepted' >&2; exit 1; fi
rm -f "$input"
cp "$work/request.json" "$work/unrelated"
chmod 600 "$work/unrelated"
ln -s "$work/unrelated" "$input"
if "$bridge" client-admin-update "$token" >/dev/null 2>&1; then echo 'symlink input accepted' >&2; exit 1; fi
[ "$(cat "$work/unrelated")" = "$(cat "$work/request.json")" ]
rm -f "$input"
ln "$work/unrelated" "$input"
if "$bridge" client-admin-update "$token" >/dev/null 2>&1; then echo 'hardlinked input accepted' >&2; exit 1; fi
rm -f "$input"
if "$bridge" client-admin-status '../state.json' >/dev/null 2>&1; then exit 1; fi
printf '%s\n' 'client-admin: detached edit/revocation, stale error job, protected one-shot inbox, secret-free read and environment sanitization passed'
printf '%s\n' 'client-admin: installed catalog, assignments, central refresh, no-op, secret-free inspection and stale-request refusal passed'

# The preceding scenario revoked this service; publish it again for enrollment.
printf '%s\n' '{"version":1,"expected_generation":7,"operation":"configure-service","payload":{"id":"test_service","client_access":true,"transports":[{"protocol":"tcp","ports":[443]}]}}' >"$work/invite-service"
ucode "$control" update <"$work/invite-service" >"$work/result"
case "${CLIENT_INVITATION_MUTATION:-}" in
 permissions) sed -i 's/ || info.mode != 0600//' /usr/libexec/ikev2-manager.d/client-access-invitation.uc ;;
 consume) sed -i "s/if (!unlink(path)) die('unable to consume invitation delivery');/if (false) die('unable to consume invitation delivery');/" /usr/libexec/ikev2-manager.d/client-access-invitation.uc ;;
esac
# The invitation is never carried by status output or ordinary inspection.
token="invite-$$"
input="/var/run/ikev2-client-admin-$token.in"
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); print(sprintf("%J",{version:1,expected_generation:0,endpoint:"https://"+s.publication.server.address+"/client/v1/enroll",id:"remote-laptop",selected_services:["test_service"],lifetime_seconds:600}));' "$state_dir/state.json" >"$input"
chmod 600 "$input"
invitation_before="$(sha256sum "$state_dir/state.json")"
test_step=issue
"$bridge" client-admin-invite "$token" >"$work/queued"
[ ! -e "$input" ]
job="$(sed -n 's/^action_id=//p' "$work/queued")"
i=0
test_step=wait
until "$bridge" client-admin-status "$job" | grep -qx 'state=ok'; do
 i=$((i+1)); [ "$i" -lt 15 ] || exit 1; sleep 1
done
test_step=status
"$bridge" client-admin-status "$job" >"$work/invite-status"
! grep -q 'https:\|invitation=' "$work/invite-status"
[ "$(sha256sum "$state_dir/state.json")" = "$invitation_before" ]
test_step=inspection
"$bridge" client-admin-show >"$work/invite-inspect"
! grep -q 'token_sha256\|invitation' "$work/invite-inspect"
# Unsafe permissions refuse delivery without consuming the private result.
result_file="/var/run/ikev2-client-admin/invitations/$job.json"
test_step=permissions
chmod 644 "$result_file"
if "$bridge" client-admin-take-invitation "$job" >"$work/refused" 2>/dev/null; then exit 1; fi
[ ! -s "$work/refused" ]
chmod 600 "$result_file"
test_step=delivery
"$bridge" client-admin-take-invitation "$job" >"$work/invitation"
[ ! -e "$result_file" ]
test_step=digest
ucode -e 'import {readfile} from "fs"; import {sha256} from "digest"; let r=json(readfile(ARGV[0])),j=json(readfile(ARGV[1])); if(r.id!="remote-laptop" || j.ledger.invitations[0].token_sha256!=sha256(split(r.invitation,"#")[1])) die("Wrong administrative invitation");' "$work/invitation" "$state_dir/invitations.json"
if "$bridge" client-admin-take-invitation "$job" >"$work/refused" 2>/dev/null; then exit 1; fi
[ ! -s "$work/refused" ]
ucode -e 'import {readfile} from "fs"; let r=json(readfile(ARGV[0])),token=split(r.invitation,"#")[1]; for(let path in [ARGV[1],ARGV[2]]) if(index(readfile(path),token)>=0) die("Raw invitation exposed in ordinary state");' "$work/invitation" "$work/invite-status" "$work/invite-inspect"
# Delivery cannot follow links or overwrite another root-private file.
test_step=symlink
ln -s "$work/invitation" "$result_file"
if "$bridge" client-admin-take-invitation "$job" >"$work/refused" 2>/dev/null; then exit 1; fi
[ -s "$work/invitation" ]
rm "$result_file"
test_step=hardlink
ln "$work/invitation" "$result_file"
if "$bridge" client-admin-take-invitation "$job" >"$work/refused" 2>/dev/null; then exit 1; fi
[ ! -s "$work/refused" ]
rm "$result_file"
test_step=expiry
cp "$work/invitation" "$result_file"; chmod 600 "$result_file"
ucode -e 'import {consume_client_invitation} from "/usr/libexec/ikev2-manager.d/client-access-invitation.uc"; let failed=false; try {consume_client_invitation(ARGV[0],time()+3601);} catch(e) {failed=true;} if(!failed) die("Expired invitation delivered");' "$job"
[ ! -e "$result_file" ]
test_step=directory
# Who is behind a device: the administrator's words, what the client reported
# and the live session, shown together and never part of what decides access.
before="$(ucode "$control" status | sed -n 's/^generation=//p')"
target="$(ucode "$control" inspect | jsonfilter -e '@.devices[0].id')"
[ -n "$target" ]
services="$(ucode "$control" inspect | jsonfilter -e '@.devices[0].selected_services')"
enabled=false
printf '{"version":1,"expected_generation":%s,"operation":"assign-device","payload":{"id":"%s","enabled":%s,"selected_services":%s,"owner":"Alice Example","note":"accounting"}}\n' "$before" "$target" "$enabled" "$services" >"$work/request.json"
ucode "$control" update <"$work/request.json" >"$work/result"
before="$(ucode "$control" status | sed -n 's/^generation=//p')"
ucode -e 'import {record_client_seen} from "/usr/libexec/ikev2-manager.d/client-access-directory.uc"; record_client_seen("/var/run/ikev2-client-seen", ARGV[0], {"x-client-host":"ALICE-PC","x-client-system":"Windows 10.0.26100","x-client-version":"2.3.0"}, "203.0.113.9", time());' "$target"
ucode "$control" inspect >"$work/inspection"
[ "$(jsonfilter -i "$work/inspection" -e '@.devices[0].owner')" = 'Alice Example' ]
[ "$(jsonfilter -i "$work/inspection" -e '@.devices[0].note')" = accounting ]
[ "$(jsonfilter -i "$work/inspection" -e '@.devices[0].host')" = ALICE-PC ]
[ "$(jsonfilter -i "$work/inspection" -e '@.devices[0].system')" = 'Windows 10.0.26100' ]
[ "$(jsonfilter -i "$work/inspection" -e '@.devices[0].seen_from')" = 203.0.113.9 ]
[ "$(jsonfilter -i "$work/inspection" -e '@.devices[0].online')" = false ]
# What a client sends is kept only in the expected shape.
ucode -e 'import {record_client_seen} from "/usr/libexec/ikev2-manager.d/client-access-directory.uc"; record_client_seen("/var/run/ikev2-client-seen", ARGV[0], {"x-client-host":"<script>","x-client-system":"Windows 10; rm -rf","x-client-version":"../1"}, "203.0.113.9", time());' "$target"
ucode "$control" inspect >"$work/inspection"
! grep -q 'script\|rm -rf\|\.\./1' "$work/inspection"
printf '{"version":1,"expected_generation":%s,"operation":"assign-device","payload":{"id":"%s","enabled":false,"selected_services":%s,"owner":"Alice <b>","note":""}}\n' "$before" "$target" "$services" >"$work/request.json"
if ucode "$control" update <"$work/request.json" >/dev/null 2>&1; then exit 1; fi
[ "$(ucode "$control" inspect | jsonfilter -e '@.devices[0].owner')" = 'Alice Example' ]
# A person's own settings - how many devices, which profiles - outlive any
# device, and a limit outside 1..16 is refused.
printf '{"version":1,"expected_generation":%s,"operation":"set-person-limit","payload":{"owner":"Carol Example","limit":3}}\n' "$before" >"$work/person.json"
ucode "$control" update <"$work/person.json" >/dev/null
printf '{"version":1,"expected_generation":%s,"operation":"assign-profiles","payload":{"owner":"Carol Example","profiles":["carol-phone"]}}\n' "$before" >"$work/person.json"
ucode "$control" update <"$work/person.json" >/dev/null
printf '{"version":1,"expected_generation":%s,"operation":"set-person-limit","payload":{"owner":"Carol Example","limit":40}}\n' "$before" >"$work/person.json"
if ucode "$control" update <"$work/person.json" >/dev/null 2>&1; then echo 'client-admin: an absurd device limit was stored' >&2; exit 1; fi
# Removal retires the identity and forgets the description.
printf '{"version":1,"expected_generation":%s,"operation":"remove-device","payload":{"id":"%s"}}\n' "$before" "$target" >"$work/request.json"
ucode "$control" update <"$work/request.json" >"$work/result" 2>/dev/null
grep -qx 'changed=1' "$work/result"
ucode "$control" inspect >"$work/inspection"
! grep -q "\"id\": \"$target\"" "$work/inspection"
! grep -q 'Alice Example' "$work/inspection"
[ ! -e "/var/run/ikev2-client-seen/$target.json" ]
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(s.person_limits["Carol Example"]!==3 || s.profile_owners["carol-phone"]!="Carol Example") die("Removing a device lost the settings of a person");' "$work/inspection"
if ucode "$control" update <"$work/request.json" >/dev/null 2>&1; then exit 1; fi
printf '%s\n' 'client-admin: device description, reported computer, refusal of markup, removal and the settings of a person passed'
printf '%s\n' 'client-admin: invitation job, secret-free status, protected one-shot delivery and expiry passed'
