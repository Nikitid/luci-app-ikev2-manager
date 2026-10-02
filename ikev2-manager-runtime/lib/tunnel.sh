#!/bin/sh
# Outbound tunnels: their names, the order they stand in for one another, and
# the data-path probe shared by the watcher and the domain router.
#
# The client section is tunnel 1, as it always was; tunnel sections tunnel_2 ..
# tunnel_8 add more. Everything a tunnel owns is numbered from its index:
#
#   tunnel  connection   child     link        if_id  mark  table     rule
#   1       proxy-out    proxy4    ipsec-out   42     0x01  1601      28001
#   N       proxy-out-N  proxy4-N  ipsec-outN  50+N   N+1   1600+N+1  28000+N+1
#
# Mark 0x02, table 1602 and rule 28002 are the WAN's, for exclusions.
#
# An exit is where a class of traffic leaves: exit N is tunnel N first, then
# every other enabled tunnel that backs the others up, in index order. Nothing
# falls back to the WAN; with none of them up the exit is unreachable.

tunnel_max=8
# A tunnel that comes back takes its traffic back only after this long up, so
# one that flaps does not break the connections on it each time.
tunnel_return_hold="${IKEV2_TUNNEL_RETURN_HOLD:-${tunnel_return_hold:-120}}"
tunnel_state_file="${IKEV2_TUNNEL_STATE:-/var/run/ikev2-tunnels.state}"

# Set the names of tunnel $1 in globals, without starting a process: the
# watcher calls this every pass.
tunnel_names() {
	tunnel_index="$1"
	if [ "$1" = 1 ]; then
		tunnel_section=client
		tunnel_conn=proxy-out
		tunnel_child=proxy4
		tunnel_link=ipsec-out
		tunnel_if_id=42
		tunnel_mark_value=1
	else
		tunnel_section="tunnel_$1"
		tunnel_conn="proxy-out-$1"
		tunnel_child="proxy4-$1"
		tunnel_link="ipsec-out$1"
		tunnel_if_id=$((50 + $1))
		tunnel_mark_value=$(($1 + 1))
	fi
	tunnel_table_id=$((1600 + tunnel_mark_value))
	tunnel_rule=$((28000 + tunnel_mark_value))
	# Marks run 1 to 9, one hex digit.
	tunnel_fwmark="0x0${tunnel_mark_value}000000"
}

# The index of a tunnel by its connection name, or nothing for another name.
tunnel_index_of_conn() {
	case "$1" in
		proxy-out) echo 1 ;;
		proxy-out-[2-8]) echo "${1#proxy-out-}" ;;
		*) return 1 ;;
	esac
}

# Read the tunnels from `uci show ikev2-manager` text on stdin into globals:
# tunnel_list (configured, in order), tunnel_on (enabled) and tunnel_spare
# (enabled and backing the others up). Parsed in the shell, without a process
# per line.
tunnel_settings_parse() {
	local line index have='' on='' off_backup=''
	while IFS= read -r line; do
		case "$line" in
			"ikev2-manager.client=client") have="$have 1" ;;
			# An option implies its section, whatever lists it.
			"ikev2-manager.client.enabled='1'") have="$have 1"; on="$on 1" ;;
			"ikev2-manager.client.backup='0'") off_backup="$off_backup 1" ;;
			ikev2-manager.tunnel_[2-8]=tunnel)
				index="${line#ikev2-manager.tunnel_}"
				have="$have ${index%%=*}" ;;
			ikev2-manager.tunnel_[2-8].enabled=\'1\')
				index="${line#ikev2-manager.tunnel_}"
				have="$have ${index%%.*}"
				on="$on ${index%%.*}" ;;
			ikev2-manager.tunnel_[2-8].backup=\'0\')
				index="${line#ikev2-manager.tunnel_}"
				off_backup="$off_backup ${index%%.*}" ;;
		esac
	done
	tunnel_list='' tunnel_on='' tunnel_spare=''
	for index in 1 2 3 4 5 6 7 8; do
		case " $have " in *" $index "*) ;; *) continue ;; esac
		tunnel_list="$tunnel_list${tunnel_list:+ }$index"
		case " $on " in *" $index "*) ;; *) continue ;; esac
		tunnel_on="$tunnel_on${tunnel_on:+ }$index"
		case " $off_backup " in *" $index "*) continue ;; esac
		tunnel_spare="$tunnel_spare${tunnel_spare:+ }$index"
	done
}

tunnel_settings_load() {
	tunnel_settings_parse <<EOF
$(uci -q show ikev2-manager 2>/dev/null)
EOF
}

# Whether more than one tunnel is configured. With one, everything is laid
# out exactly as it was before there could be more.
tunnel_several() {
	case "$tunnel_list" in *' '*) return 0 ;; esac
	return 1
}

# Set tunnel_chain to the tunnels exit $1 may use, most preferred first.
tunnel_exit_chain() {
	local exit="$1" index
	tunnel_chain=''
	case " $tunnel_on " in *" $exit "*) tunnel_chain="$exit" ;; esac
	for index in $tunnel_spare; do
		[ "$index" != "$exit" ] || continue
		tunnel_chain="$tunnel_chain${tunnel_chain:+ }$index"
	done
}

# Choose the tunnel of every exit. Arguments: the time now and the tunnels up
# now, as one word list. Reads and rewrites the state file, which remembers
# since when each tunnel has been up and what each exit uses; sets
# tunnel_changes to an "exit:tunnel" word for each exit whose tunnel changed,
# 0 for none. Nothing is printed, so the watcher calls it without a subshell.
#
# An exit keeps a tunnel that is still up. One that went down is replaced at
# once by the first tunnel up in its chain. A tunnel ahead of the current one
# takes the exit back after tunnel_return_hold seconds up.
tunnel_select() {
	local now="$1" up=" $2 " line kind index value since_list='' old_list=''
	local exit current pick candidate since new_state='' old_state=''
	tunnel_changes=''
	if [ -r "$tunnel_state_file" ]; then
		while IFS=' ' read -r kind index value; do
			old_state="${old_state}$kind $index $value
"
			case "$kind" in
				ready) since_list="$since_list $index:$value" ;;
				exit) old_list="$old_list $index:$value" ;;
			esac
		done <"$tunnel_state_file"
	fi
	for index in $tunnel_on; do
		case "$up" in *" $index "*) ;; *) continue ;; esac
		since="$now"
		for line in $since_list; do
			[ "${line%%:*}" = "$index" ] && since="${line#*:}"
		done
		new_state="${new_state}ready $index $since
"
	done
	for exit in $tunnel_list; do
		tunnel_exit_chain "$exit"
		current=0
		for line in $old_list; do
			[ "${line%%:*}" = "$exit" ] && current="${line#*:}"
		done
		pick=0
		case " $tunnel_chain " in
			*" $current "*)
				case "$up" in *" $current "*) pick="$current" ;; esac ;;
		esac
		if [ "$pick" = 0 ]; then
			for candidate in $tunnel_chain; do
				case "$up" in *" $candidate "*) pick="$candidate"; break ;; esac
			done
		else
			for candidate in $tunnel_chain; do
				[ "$candidate" != "$pick" ] || break
				case "$up" in *" $candidate "*) ;; *) continue ;; esac
				since="$now"
				for line in $since_list; do
					[ "${line%%:*}" = "$candidate" ] && since="${line#*:}"
				done
				if [ $((now - since)) -ge "$tunnel_return_hold" ]; then
					pick="$candidate"
					break
				fi
			done
		fi
		new_state="${new_state}exit $exit $pick
"
		[ "$pick" = "$current" ] ||
			tunnel_changes="$tunnel_changes${tunnel_changes:+ }$exit:$pick"
	done
	# Written only when it changed: the watcher calls this every pass.
	[ "$new_state" != "$old_state" ] || return 0
	printf '%s' "$new_state" >"$tunnel_state_file.new" &&
		mv "$tunnel_state_file.new" "$tunnel_state_file"
}

# The tunnel exit $1 uses, 0 for none, as last chosen by the watcher.
tunnel_exit_selected() {
	local kind index value
	[ -r "$tunnel_state_file" ] || return 1
	while IFS=' ' read -r kind index value; do
		[ "$kind" = exit ] && [ "$index" = "$1" ] || continue
		echo "$value"
		return 0
	done <"$tunnel_state_file"
	return 1
}

# Succeed when HTTPS crosses the link of a tunnel, ipsec-out unless named.
# Binding by device is the only reliable way to use the tunnel from the
# router: binding the tunnel address still routes over WAN. The IP-literal
# endpoint goes first, so the probe does not depend on DNS; both endpoints are
# third parties and either can fail on its own.
# Arguments: connect timeout and total time per endpoint, in seconds; link.
tunnel_https_reachable() {
	local connect="${1:-3}" total="${2:-5}" link="${3:-ipsec-out}"
	curl -4fsS --interface "$link" \
		--connect-timeout "$connect" --max-time "$total" \
		https://1.1.1.1/cdn-cgi/trace 2>/dev/null |
		grep -q '^ip=[0-9]' && return 0
	curl -4fsS --interface "$link" \
		--connect-timeout "$connect" --max-time "$total" \
		https://checkip.amazonaws.com 2>/dev/null |
		grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}
