#!/bin/sh
# Sourced by client-ike.sh after a real inbound EAP login. All changes stay in
# its disposable namespaces; the required exit also negotiates a real IKE SA.
path_exit="ikev2-auth-exit-$$"
[ ! -e "/etc/netns/$path_exit" ] || fail 'exit namespace configuration already exists'
ip netns add "$path_exit"
created="$created $path_exit"
mkdir -p "$work/$path_exit/run" "/etc/netns/$path_exit/swanctl"
cp "/etc/netns/$server/strongswan.conf" "/etc/netns/$path_exit/strongswan.conf"
ip -n "$path_exit" link set lo up
ip netns exec "$server" ip link add exit-transit type veth peer name exit-peer netns "$path_exit"
ip -n "$server" addr add 10.233.254.1/24 dev exit-transit
ip -n "$path_exit" addr add 10.233.254.2/24 dev exit-peer
ip -n "$server" link set exit-transit up
ip -n "$path_exit" link set exit-peer up
for namespace in "$server" "$path_exit"; do
	ip -n "$namespace" link add ipsec-out type xfrm dev lo if_id 42
	ip -n "$namespace" link set ipsec-out up
done
ip -n "$server" addr add 10.26.0.10/32 dev ipsec-out
ip -n "$path_exit" addr add 192.0.2.9/32 dev lo
ip -n "$path_exit" addr add 192.0.2.53/32 dev lo
ip -n "$path_exit" route add 10.26.0.10/32 dev ipsec-out
ip -n "$server" route add default via 10.233.254.2
ip -n "$server" route add default dev ipsec-out src 10.26.0.10 table 1550
ip -n "$server" rule add oif ipsec-out lookup 1550 priority 10990
ip -n "$server" rule add from 10.26.0.10/32 lookup 1550 priority 10991
ip netns exec "$server" sysctl -q -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.ipsec-out.rp_filter=0
path_secret="$(openssl rand -hex 24)"
cat >>"/etc/netns/$server/swanctl/swanctl.conf" <<CONF
connections {
 proxy-out {
  version = 2
  local_addrs = 10.233.254.1
  remote_addrs = 10.233.254.2
  proposals = aes256gcm16-prfsha384-ecp384
  local { auth = psk
   id = router.test
  }
  remote { auth = psk
   id = exit.test
  }
  children { proxy4 {
   local_ts = 10.26.0.10/32
   remote_ts = 0.0.0.0/0
   esp_proposals = aes256gcm16-ecp384
   if_id_in = 42
   if_id_out = 42
  } }
 }
}
secrets { ike-path { id-1 = router.test
 id-2 = exit.test
 secret = "$path_secret"
} }
CONF
cat >"/etc/netns/$path_exit/swanctl/swanctl.conf" <<CONF
connections {
 exit {
  version = 2
  local_addrs = 10.233.254.2
  proposals = aes256gcm16-prfsha384-ecp384
  local { auth = psk
   id = exit.test
  }
  remote { auth = psk
   id = router.test
  }
  children { proxy4 {
   local_ts = 0.0.0.0/0
   remote_ts = 10.26.0.10/32
   esp_proposals = aes256gcm16-ecp384
   if_id_in = 42
   if_id_out = 42
  } }
 }
}
secrets { ike-path { id-1 = router.test
 id-2 = exit.test
 secret = "$path_secret"
} }
CONF
unset path_secret
role "$path_exit" /usr/lib/ipsec/charon >"$work/$path_exit/daemon.log" 2>&1 &
i=0
until role "$path_exit" swanctl --stats >/dev/null 2>&1; do
	i=$((i + 1)); [ "$i" -lt 15 ] || fail 'exit daemon startup failed'
	sleep 1
done
role "$path_exit" swanctl --load-all >"$work/exit-load.log" 2>&1 || fail 'exit configuration load failed'
role "$server" swanctl --load-all >"$work/router-reload.log" 2>&1 || fail 'router exit configuration load failed'
pkg_run_bounded 25 role "$server" swanctl --initiate --child proxy4 >"$work/exit-login.log" 2>&1 || fail 'required exit IKE login failed'
ip netns exec "$path_exit" nft -f - <<'NFT'
table inet path_evidence {
 counter encrypted_service { }
 counter direct_service { }
 counter encrypted_dns { }
 counter direct_dns { }
 chain input {
  type filter hook input priority 0;
  iifname "ipsec-out" meta l4proto { tcp, udp } th dport { 4443, 4444 } counter name encrypted_service
  iifname "exit-peer" meta l4proto { tcp, udp } th dport { 4443, 4444 } counter name direct_service
  iifname "ipsec-out" tcp dport 53 counter name encrypted_dns
  iifname "exit-peer" tcp dport 53 counter name direct_dns
 }
}
NFT
ip netns exec "$path_exit" socat -v TCP4-LISTEN:4443,bind=192.0.2.9,reuseaddr,fork EXEC:/bin/cat >"$work/exit-echo.log" 2>&1 &
ip netns exec "$path_exit" socat -T 2 UDP4-RECVFROM:4444,bind=192.0.2.9,reuseaddr,fork PIPE >"$work/exit-udp.log" 2>&1 &
ip netns exec "$path_exit" dnsmasq --keep-in-foreground --no-resolv --no-hosts --bind-interfaces --listen-address=192.0.2.53 --address=/api.example.com/192.0.2.9 --pid-file="$work/dnsmasq.pid" >"$work/exit-dns.log" 2>&1 &
ucode -e 'import {readfile} from "fs"; print(sprintf("%J", {version:1,state:json(readfile(ARGV[0])),exit_link:"ipsec-out",dns_address:"192.0.2.53",dns_port:53,listen_port:17896}));' "$work/state/state.json" >"$work/path-input.json"
ucode "$lib/client-access-policy.uc" path <"$work/path-input.json" >"$work/path.json" || fail 'managed path compilation failed'
ucode -e 'import {readfile} from "fs"; let config=json(readfile(ARGV[0])).config; config.log.level="debug"; print(sprintf("%J",config));' "$work/path.json" >"$work/runtime/proxy.json"
ucode -e 'import {readfile} from "fs"; print(json(readfile(ARGV[0])).nft);' "$work/path.json" >"$work/path.nft"
ip netns exec "$server" sing-box check -c "$work/runtime/proxy.json" >"$work/proxy-check.log" 2>&1 || fail 'managed proxy configuration rejected'
ip netns exec "$server" nft -f "$work/path.nft" || fail 'managed interception rejected'
ip -n "$server" route add local 172.31.254.0/24 dev lo table 1506
ip -n "$server" rule add iif ipsec-in to 172.31.254.0/24 lookup 1506 priority 10998
ip netns exec "$server" sing-box run -c "$work/runtime/proxy.json" >"$work/proxy.log" 2>&1 &
path_proxy_pid=$!
path_proof() {
 local fingerprint
 fingerprint="$(role "$server" sh -c 'runtime_lib_dir="$1"; nft_bin=/usr/sbin/nft; ucode_bin=/usr/bin/ucode; table=ikev2_client_path; . "$1/nft-runtime.sh"; runtime_fingerprint' sh "$lib")" || fail 'path kernel fingerprint unavailable'
 ucode -e 'import {readfile,writefile,chmod,rename} from "fs"; import {sha256} from "digest";
 let state=json(readfile(ARGV[0])), directory=ARGV[1], pid=+ARGV[2], fp=ARGV[3];
 let proof={version:1,generation:state.generation,exit:state.publication.exit,
 config_sha256:sha256(readfile(directory+"/proxy.json")),nft_sha256:fp,proxy_pid:pid,
 proxy_start:split(readfile("/proc/"+pid+"/stat")," ")[21]};
 if(!writefile(directory+"/path-ready.new",sprintf("%J\n",proof)) || !chmod(directory+"/path-ready.new",0600) || !rename(directory+"/path-ready.new",directory+"/path-ready.json")) die("Unable to stamp test path");' "$work/state/state.json" "$work/runtime" "$path_proxy_pid" "$fingerprint" || fail 'path proof publication failed'
}
sleep 1
path_proof
path_required=1
# Run the existing inbound user policy with all broad access denied. Its
# sessions are derived from this daemon's real VICI snapshot, not invented IDs.
mkdir -m 700 "$work/policy-config"
cat >"$work/policy-config/ikev2-manager" <<'UCI'
config globals 'globals'
 option configured '1'
config server 'server'
 option enabled '1'
 option pool4 '10.25.0.10-10.25.0.10'
 option allow_router '0'
 option allow_internet '0'
 option allow_lan '0'
UCI
printf 'alice\n' >"$work/users.db"
role "$server" swanmon list-sas >"$work/policy-vici.json"
ucode "$lib/client-access-policy.uc" sessions <"$work/policy-vici.json" >"$work/policy-sessions.json"
ucode -e 'import {readfile} from "fs"; for(let session in json(readfile(ARGV[0]))) print(session.identity + "\t" + session.address + "\n");' "$work/policy-sessions.json" >"$work/policy-sessions"
cp "${CLIENT_ACCESS_USER_POLICY_HELPER:-/usr/libexec/ikev2-user-policy}" "$work/user-policy.sh"
role "$server" env IKEV2_RUNTIME_LIB_DIR="$lib" IKEV2_CLIENT_STATE_DIR="$work/state" IKEV2_UCI_CONFIG_DIR="$work/policy-config" IKEV2_USERS_DB="$work/users.db" IKEV2_SESSIONS_FILE="$work/policy-sessions" IKEV2_USER_POLICY_SIGNATURE="$work/policy.signature" IKEV2_USER_POLICY_SESSIONS="$work/policy.runtime-sessions" IKEV2_USER_POLICY_FINGERPRINTS="$work/policy.fingerprints" IKEV2_USER_POLICY_LOCK="$work/policy.lock" TMPDIR="$work" sh "$work/user-policy.sh" sync >"$work/policy.log" 2>&1 || fail 'existing inbound policy installation failed'
controller sync || fail 'path admission refresh failed'
seen_path() {
	ip netns exec "$path_exit" nft list counter inet path_evidence "$1" | sed -n 's/.*packets \([0-9]*\).*/\1/p'
}
[ "$(probe)" = authenticated-path ] || fail 'inbound IKE to proxy to required exit TCP failed'
# What other software on a router does to marks: restore a connection mark over
# the whole packet mark of an established flow, between this path's
# interception and delivery. The flow must survive it, and still be closed
# without admission.
ip netns exec "$server" nft -f - <<'NFT'
table ip foreign_marks {
 chain prerouting {
  type filter hook prerouting priority mangle; policy accept;
  ct state established,related meta mark set ct mark & 0x0000ff00
 }
}
NFT
[ "$(probe)" = authenticated-path ] || fail 'a foreign mark rewrite broke an admitted flow'
[ "$(udp_probe)" = authenticated-udp ] || fail 'a foreign mark rewrite broke admitted UDP'
[ -z "$(probe 4446 || :)" ] || fail 'a foreign mark rewrite admitted an unselected port'
[ "$(udp_probe)" = authenticated-udp ] || fail 'inbound IKE to proxy to required exit UDP failed'
[ -z "$(probe 4446 || :)" ] || fail 'existing policy admitted unselected port' 
[ "$(seen_path encrypted_service)" -gt 0 ] || fail 'service did not cross required encrypted exit'
[ "$(seen_path encrypted_dns)" -gt 0 ] || fail 'DNS did not cross required encrypted exit'
[ "$(seen_path direct_service)" = 0 ] || fail 'service leaked to direct route'
[ "$(seen_path direct_dns)" = 0 ] || fail 'DNS leaked to direct route'
# The direct path remains usable while the required exit is unavailable.
ip -n "$server" link set ipsec-out down
controller sync || fail 'exit-down admission refresh failed'
[ -z "$(probe || :)" ] || fail 'service survived required exit loss'
[ -z "$(udp_probe || :)" ] || fail 'UDP survived required exit loss'
[ "$(seen_path direct_service)" = 0 ] || fail 'exit loss leaked service to direct route'
printf 'direct-control\n' | ip netns exec "$server" socat -T 2 - TCP4:192.0.2.9:4443,connect-timeout=2 >"$work/direct-control"
[ "$(cat "$work/direct-control")" = direct-control ] || fail 'direct control route unavailable'
[ "$(seen_path direct_service)" -gt 0 ] || fail 'direct-path negative control not detected'
ip -n "$server" link set ipsec-out up
controller sync || fail 'exit restoration admission refresh failed'
[ "$(probe)" = authenticated-path ] || fail 'required exit recovery failed'
# A live interface without an installed exit SA is also an unavailable path.
path_direct_before="$(seen_path direct_service)"
path_dns_before="$(seen_path direct_dns)"
pkg_run_bounded 10 role "$server" swanctl --terminate --ike proxy-out >"$work/exit-terminate.log" 2>&1 || fail 'required exit termination failed'
controller sync || fail 'exit-session loss admission refresh failed'
[ -z "$(probe || :)" ] || fail 'service survived required exit SA loss'
[ -z "$(udp_probe || :)" ] || fail 'UDP survived required exit SA loss'
[ "$(seen_path direct_service)" = "$path_direct_before" ] || fail 'exit SA loss leaked service directly'
[ "$(seen_path direct_dns)" = "$path_dns_before" ] || fail 'exit SA loss leaked DNS directly'
pkg_run_bounded 25 role "$server" swanctl --initiate --child proxy4 >"$work/exit-reconnect.log" 2>&1 || fail 'required exit reconnect failed'
controller sync || fail 'exit-session recovery admission refresh failed'
[ "$(probe)" = authenticated-path ] || fail 'required exit session recovery failed'
[ "$(udp_probe)" = authenticated-udp ] || fail 'required exit UDP session recovery failed'
kill "$path_proxy_pid"
wait "$path_proxy_pid" 2>/dev/null || :
if controller sync; then fail 'dead proxy was considered current'; fi
[ -z "$(probe || :)" ] || fail 'service survived managed proxy loss'
[ -z "$(udp_probe || :)" ] || fail 'UDP survived managed proxy loss'
# No admission table means no admission mark. Interception must stay closed
# even while the proxy and its required exit are healthy.
ip netns exec "$server" sing-box run -c "$work/runtime/proxy.json" >"$work/proxy-restart.log" 2>&1 &
path_proxy_pid=$!
sleep 1
path_proof
controller sync || fail 'proxy restoration admission refresh failed'
[ "$(probe)" = authenticated-path ] || fail 'managed proxy recovery failed'
ip netns exec "$server" nft delete table inet ikev2_client_access
[ -z "$(probe || :)" ] || fail 'missing admission table allowed service'
[ -z "$(udp_probe || :)" ] || fail 'missing admission table allowed UDP'
controller sync || fail 'missing admission table recovery failed'
[ "$(probe)" = authenticated-path ] || fail 'admission table recovery failed'
# A changed kernel program or process start stamp invalidates readiness.
cp "$work/runtime/path-ready.json" "$work/path-ready.saved"
ucode -e 'import {readfile,writefile} from "fs"; let p=json(readfile(ARGV[0])); p.proxy_start="0"; writefile(ARGV[0],sprintf("%J\n",p));' "$work/runtime/path-ready.json"
if controller sync; then fail 'replaced process stamp was accepted'; fi
[ -z "$(probe || :)" ] || fail 'invalid process stamp retained access'
cp "$work/path-ready.saved" "$work/runtime/path-ready.json"
controller sync || fail 'restored process stamp rejected'
ip netns exec "$server" nft add rule inet ikev2_client_path forward counter
if controller sync; then fail 'changed kernel path was accepted'; fi
[ -z "$(udp_probe || :)" ] || fail 'changed kernel path retained UDP access'
{ printf 'delete table inet ikev2_client_path\n'; cat "$work/path.nft"; } >"$work/path-restore.nft"
ip netns exec "$server" nft -f "$work/path-restore.nft"
path_proof
controller sync || fail 'restored kernel path rejected'
# Changing committed generation must close admission until that generation's
# active path is acknowledged. A stale proof must never authorize a new policy.
ucode "$fixture" "$work/state" revoke
if controller sync; then fail 'stale path generation was accepted'; fi
[ -z "$(probe || :)" ] || fail 'generation mismatch retained TCP admission'
ucode "$fixture" "$work/state" enable
if controller sync; then fail 'new generation used old path acknowledgement'; fi
[ -z "$(udp_probe || :)" ] || fail 'generation mismatch retained UDP admission'
path_proof
controller sync || fail 'current path acknowledgement did not restore admission'
[ "$(probe)" = authenticated-path ] || fail 'generation acknowledgement recovery failed'
printf '%s\n' 'client-path: actual inbound/exit IKE, TProxy TCP/UDP, tunnel DNS, exit interface/SA loss and recovery, proxy loss, missing admission table and generation/process/kernel readiness passed'
# Exercise the production activation writer without the manual proof producer.
kill "$path_proxy_pid"
wait "$path_proxy_pid" 2>/dev/null || :
rm -f "$work/runtime/path-ready.json"
ip -n "$server" rule del iif ipsec-in to 172.31.254.0/24 lookup 1506 priority 10998
ip -n "$server" route del local 172.31.254.0/24 dev lo table 1506
ip -n "$server" addr del 172.31.254.1/32 dev lo
cat >"$work/uci" <<'UCI'
#!/bin/sh
case "$*" in
 '-q get ikev2-manager.server.enabled') echo 1 ;;
 '-q get ikev2-manager.server.pool4') echo 10.25.0.10-10.25.0.10 ;;
 '-q get ikev2-manager.client.tunnel_dns_bootstrap') echo 192.0.2.53:53 ;;
 '-q show ikev2-manager') printf "ikev2-manager.client=client\nikev2-manager.client.enabled='1'\n" ;;
 *) exit 1 ;;
esac
UCI
printf 'exit 1 1\n' >"$work/tunnels.state"
path_auto=1
controller sync || fail 'automatic path activation failed'
[ "$(probe)" = authenticated-path ] || fail 'automatically activated TCP path failed'
[ "$(udp_probe)" = authenticated-udp ] || fail 'automatically activated UDP path failed'
path_proxy_pid="$(role "$server" ucode "$lib/client-access-path-control.uc" owner "$work/runtime")" || fail 'owned automatic proxy missing'
controller sync || fail 'automatic path reconciliation failed'
[ "$(role "$server" ucode "$lib/client-access-path-control.uc" owner "$work/runtime")" = "$path_proxy_pid" ] || fail 'unchanged path restarted proxy'
kill "$path_proxy_pid"
sleep 1
controller sync || fail 'automatic proxy recovery failed'
[ "$(probe)" = authenticated-path ] || fail 'automatic proxy recovery lost TCP'
[ "$(udp_probe)" = authenticated-udp ] || fail 'automatic proxy recovery lost UDP'
ucode "$fixture" "$work/state" revoke
controller sync || fail 'automatic revocation failed'
[ -z "$(probe || :)" ] || fail 'automatic revocation retained access'
ucode "$fixture" "$work/state" enable
controller sync || fail 'automatic generation activation failed'
[ "$(probe)" = authenticated-path ] || fail 'automatic generation recovery lost TCP'
path_proxy_pid="$(role "$server" ucode "$lib/client-access-path-control.uc" owner "$work/runtime")"
ucode "$fixture" "$work/state" add-domain
controller sync || fail 'central domain update activation failed'
[ "$(role "$server" ucode "$lib/client-access-path-control.uc" owner "$work/runtime")" != "$path_proxy_pid" ] || fail 'changed config retained old proxy'
printf 'new-domain\n' | ip netns exec "$client" socat -T 2 - TCP4:172.31.254.2:4443,connect-timeout=2,shut-none >"$work/new-domain"
[ "$(cat "$work/new-domain")" = new-domain ] || fail 'new centrally published domain unavailable'
ip -n "$server" rule add to 192.0.2.0/24 lookup main priority 10998
if controller sync; then fail 'foreign rule slot was accepted'; fi
[ -z "$(udp_probe || :)" ] || fail 'foreign rule conflict retained access'
ip -n "$server" rule del to 192.0.2.0/24 lookup main priority 10998
controller sync || fail 'route conflict recovery failed'
ip -n "$server" route add blackhole 172.31.254.128/25
if controller sync; then fail 'overlapping destination route was accepted'; fi
[ -z "$(probe || :)" ] || fail 'overlap conflict retained access'
ip -n "$server" route del blackhole 172.31.254.128/25
controller sync || fail 'overlap conflict recovery failed'
# A router activated before its first device: the path is brought up, nothing
# is admitted, and the controller reports that as closed rather than failed.
mkdir -m 700 "$work/empty"
ucode "$fixture" "$work/empty" seed-empty
mv "$work/state" "$work/state.devices"
mv "$work/empty" "$work/state"
controller sync || fail 'a router without devices failed its sync'
grep -q '^state=closed$' "$work/runtime/status" || fail 'a router without devices did not report closed'
[ ! -e "$work/runtime/device-ready.json" ] || fail 'a router without devices kept device evidence'
[ -z "$(probe || :)" ] || fail 'a router without devices admitted a session'
mv "$work/state" "$work/empty"
mv "$work/state.devices" "$work/state"
controller sync || fail 'returning the devices failed'
[ "$(probe)" = authenticated-path ] || fail 'returning the devices did not restore access'
controller close || fail 'automatic path close failed' 
if role "$server" ucode "$lib/client-access-path-control.uc" owner "$work/runtime" >/dev/null 2>&1; then fail 'close retained owned proxy'; fi
[ -z "$(probe || :)" ] || fail 'closed automatic path retained access'
printf '%s\n' 'client-path: automatic activation, process reuse/recovery, generation updates, foreign route refusal and close passed'
