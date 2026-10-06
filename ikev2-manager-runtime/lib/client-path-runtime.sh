#!/bin/sh
# Dedicated proxy lifecycle. Only the committed catalog and local exit watcher
# may choose its path; unrelated routes, processes and tables are never replaced.
client_path_control() {
 "$ucode_bin" "$runtime_lib_dir/client-access-path-control.uc" "$@" 2>/dev/null
}

client_path_stop() {
 local pid remaining=5
 rm -f "$runtime_dir/path-ready.json"
 pid="$(client_path_control owner "$runtime_dir")" || return 0
 kill "$pid" 2>/dev/null || return 1
 while client_path_control owner "$runtime_dir" >/dev/null; do
  remaining=$((remaining - 1))
  [ "$remaining" -gt 0 ] || { kill -KILL "$pid" 2>/dev/null || return 1; break; }
  sleep 1
 done
 rm -f "$runtime_dir/proxy-owner.json"
}

client_path_routes() {
 local subnet
 subnet="$(jsonfilter -i "$work/path-plan.json" -e '@.virtual_subnet')" || return 1
 ip -j -4 rule show >"$work/path-rules.json" &&
  ip -j -4 route show table all >"$work/path-routes.json" &&
  client_path_control routes "$runtime_dir" "$work/path-plan.json" "$work/path-rules.json" "$work/path-routes.json" >"$work/path-slots.json" || return 1
 if [ "$(jsonfilter -i "$work/path-slots.json" -e '@.route_present')" != true ]; then
  ip -4 route add local "$subnet" dev lo table 1506 || return 1
 fi
 if [ "$(jsonfilter -i "$work/path-slots.json" -e '@.rule_present')" != true ]; then
  ip -4 rule add iif ipsec-in to "$subnet" lookup 1506 priority 10998 || return 1
 fi
}

client_path_sync() {
 [ "$require_path" = 1 ] && [ "$auto_path" = 1 ] || return 0
 local exit selected endpoint address port pid fingerprint remaining=5
 exit="$(jsonfilter -i "$work/plan.json" -e '@.exit')" || return 1
 tunnel_exit_valid "$exit" || return 1
 tunnel_settings_parse <<SETTINGS
$("$uci_bin" -q show ikev2-manager 2>/dev/null)
SETTINGS
 tunnel_exit_chain "$exit"
 selected="$(tunnel_exit_selected "$exit")" || return 1
 case " $tunnel_chain " in *" $selected "*) ;; *) return 1 ;; esac
 case "$selected" in [1-7]) ;; *) return 1 ;; esac
 tunnel_names "$selected"
 ip -j -d link show dev "$tunnel_link" >"$work/path-link.json" &&
  "$ucode_bin" -e 'import {readfile} from "fs"; let links=json(readfile(ARGV[0])); if(length(links)!=1 || links[0].linkinfo?.info_kind!="xfrm" || +links[0].linkinfo.info_data.if_id!=+ARGV[1] || index(links[0].flags,"UP")<0) exit(1);' "$work/path-link.json" "$tunnel_if_id" || return 1
 endpoint="$("$uci_bin" -q get ikev2-manager.client.tunnel_dns_bootstrap 2>/dev/null)" || return 1
 # The compiler validates the literal endpoint; DNS never bootstraps via WAN.
 endpoint="${endpoint%% *}"
 address="${endpoint%:*}"; port="${endpoint##*:}"
 [ "$address" != "$endpoint" ] || return 1
 client_path_control prepare "$state_dir" "$tunnel_link" "$address" "$port" 17896 >"$work/path-plan.json" || return 1
 "$ucode_bin" -e 'import {readfile} from "fs"; let p=json(readfile(ARGV[0])); print(sprintf("%J\n",p.config));' "$work/path-plan.json" >"$work/proxy.next.json" || return 1
 # Fast path retains active sockets only when the applied generation is current.
 if cmp -s "$work/proxy.next.json" "$runtime_dir/proxy.json" && path_current; then
  client_path_routes
  return $?
 fi
 close_grants || return 1
 rm -f "$runtime_dir/path-ready.json"
 pkg_run_bounded 5 /usr/bin/sing-box check -c "$work/proxy.next.json" >/dev/null 2>&1 || return 1
 client_path_routes || return 1
 (
  table=ikev2_client_path
  : >"$work/path-install.nft"
  if runtime_exists; then
   runtime_owned || exit 1
   printf 'delete table inet %s\n' "$table" >>"$work/path-install.nft"
  fi
  "$ucode_bin" -e 'import {readfile} from "fs"; print(json(readfile(ARGV[0])).nft);' "$work/path-plan.json" >>"$work/path-install.nft" || exit 1
  pkg_run_bounded 3 "$nft_bin" -c -f "$work/path-install.nft" >/dev/null 2>&1 &&
   pkg_run_bounded 3 "$nft_bin" -f "$work/path-install.nft" >/dev/null 2>&1 && runtime_owned
 ) || return 1
 # A file update is never mistaken for a running-process update.
 client_path_stop || return 1
 cp "$work/proxy.next.json" "$runtime_dir/proxy.next.json" &&
  chmod 600 "$runtime_dir/proxy.next.json" && mv "$runtime_dir/proxy.next.json" "$runtime_dir/proxy.json" || return 1
 /usr/bin/sing-box run -c "$runtime_dir/proxy.json" >/dev/null 2>&1 &
 pid=$!
 until client_path_control record "$runtime_dir" "$pid"; do
  remaining=$((remaining - 1)); [ "$remaining" -gt 0 ] || return 1
  sleep 1
 done
 fingerprint="$(table=ikev2_client_path; runtime_owned && runtime_fingerprint)" || return 1
 remaining=5
 until client_path_control stamp "$runtime_dir" "$state_dir" "$work/path-plan.json" "$fingerprint"; do
  remaining=$((remaining - 1)); [ "$remaining" -gt 0 ] || { client_path_stop; return 1; }
  sleep 1
 done
}
