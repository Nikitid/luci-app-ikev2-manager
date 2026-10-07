// First activation and listener settings for managed desktop access. The
// request chooses a port, an exit and, once, the virtual subnet; the server
// identity and every path come from this router's own configuration.
'use strict';
import { stdin, lstat, mkdir, chmod, popen } from 'fs';
import { publish_client_state, read_client_state } from './client-access-store.uc';
import { client_desired_state } from './client-access-admin.uc';

let directory = '/etc/ikev2-manager/clients';

function command(line) {
	let child = popen(line, 'r');
	if (!child) die('command unavailable');
	let body = child.read(1048577), status = child.close();
	return status == 0 && type(body) == 'string' && length(body) <= 1048576 ? body : null;
}
function option(name) {
	if (!match(name, /^[a-z_]+\.[a-z0-9_]+$/)) die('invalid option');
	return replace(command('/sbin/uci -q get ikev2-manager.' + name) ?? '', /\n$/, '');
}
function number(address) {
	let parts = split(address, '.'), value = 0;
	if (length(parts) != 4) die('invalid address');
	for (let part in parts) {
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || +part > 255) die('invalid address');
		value = value * 256 + +part;
	}
	return value;
}
function network(cidr) {
	let parts = split(cidr, '/');
	if (length(parts) != 2 || !match(parts[1], /^([0-9]|[12][0-9]|3[0-2])$/)) die('invalid network');
	let size = 2 ** (32 - +parts[1]), first = number(parts[0]);
	first -= first % size;
	return { first: first, last: first + size - 1 };
}
function private_subnet(cidr) {
	if (type(cidr) != 'string' || !match(cidr, /^[0-9.]{7,15}\/(1[6-9]|2[0-8])$/)) return false;
	let net = network(cidr);
	if (net.first != number(split(cidr, '/')[0])) return false;
	for (let block in [ '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16' ]) {
		let outer = network(block);
		if (net.first >= outer.first && net.last <= outer.last) return true;
	}
	return false;
}
// Everything this router already answers for or hands out: its interface
// networks, its routes and the inbound address pool.
function occupied() {
	let ranges = [];
	for (let link in json(command('/sbin/ip -j -4 address show') ?? '[]'))
		for (let address in link.addr_info ?? [])
			if (address.local != null && link.ifname != 'lo') push(ranges, network(`${address.local}/${address.prefixlen}`));
	for (let route in json(command('/sbin/ip -j -4 route show') ?? '[]'))
		if (type(route.dst) == 'string' && route.dst != 'default') push(ranges, network(index(route.dst, '/') < 0 ? route.dst + '/32' : route.dst));
	let pool = split(option('server.pool4'), '-');
	if (length(pool) == 2) push(ranges, { first: number(pool[0]), last: number(pool[1]) });
	return ranges;
}
function tunnels() {
	let found = {};
	for (let line in split(command('/sbin/uci -q show ikev2-manager') ?? '', '\n')) {
		if (line == "ikev2-manager.client.enabled='1'") found['1'] = true;
		let other = match(line, /^ikev2-manager\.tunnel_([2-7])\.enabled='1'$/);
		if (other) found[other[1]] = true;
	}
	return sort(keys(found));
}
function initialized() { return lstat(directory + '/initialized') != null; }
function identity() {
	let name = option('server.identity');
	return match(name, /^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$/) && index(name, '.') > 0 && !match(name, /^[0-9.]+$/) ? name : null;
}

try {
	if (ARGV[0] == 'show' && length(ARGV) == 1) {
		let state = initialized() ? read_client_state(directory) : null, port = option('client_access.port');
		print(sprintf('%J\n', { version: 1, initialized: state != null,
			enabled: option('client_access.enabled') == '1', port: match(port, /^[0-9]{4,5}$/) ? +port : 8443,
			server_enabled: option('server.enabled') == '1', server_identity: identity(),
			custom_server: option('server.custom_config') == '1',
			virtual_subnet: state?.publication?.virtual_subnet, exit: state?.publication?.exit, tunnels: tunnels() }));
	} else if (ARGV[0] == 'apply' && length(ARGV) == 1) {
		let raw = stdin.read(4097);
		if (type(raw) != 'string' || length(raw) > 4096) die('oversized request');
		let request = json(raw);
		if (type(request) != 'object' || length(keys(request)) != 5 || request.version !== 1 ||
			type(request.enabled) != 'bool' || type(request.port) != 'int' || request.port < 1024 || request.port > 65535 ||
			type(request.exit) != 'string' || !match(request.exit, /^[1-7]s?$/) || !private_subnet(request.virtual_subnet))
			die('invalid request');
		if (index(tunnels(), substr(request.exit, 0, 1)) < 0) die('exit tunnel is not enabled');
		let name = identity();
		if (request.enabled && (option('server.enabled') != '1' || name == null)) die('inbound server required');
		if (!initialized()) {
			if (name == null) die('inbound server identity required');
			let wanted = network(request.virtual_subnet);
			for (let used in occupied())
				if (wanted.first <= used.last && used.first <= wanted.last) die('virtual subnet is in use');
			// A fixed path, protected ancestors and no symlink traversal.
			for (let path in [ '/etc', '/etc/ikev2-manager', directory ]) {
				let info = lstat(path);
				if (info == null && path != '/etc') {
					if (!mkdir(path, 0700) || !chmod(path, 0700)) die('unable to create client directory');
					info = lstat(path);
				}
				if (info?.type != 'directory' || info.uid != 0 || (info.mode & 0022) != 0) die('unsafe publication ancestor');
			}
			publish_client_state(directory, { version: 1, server: { address: name, remote_id: name },
				virtual_subnet: request.virtual_subnet, exit: request.exit, services: [], devices: [] }, 0, true);
		} else {
			let state = read_client_state(directory), desired = client_desired_state(state);
			// Enrolled devices carry this subnet in their denials and names.
			if (desired.virtual_subnet != request.virtual_subnet) die('virtual subnet cannot change');
			if (desired.exit != request.exit) {
				desired.exit = request.exit;
				publish_client_state(directory, desired, state.generation, false);
			}
		}
		print(`enabled=${request.enabled ? 1 : 0}\nport=${request.port}\n`);
	} else {
		warn('usage: client-access-setup.uc show|apply\n');
		exit(2);
	}
} catch (error) {
	warn('client-access-setup: settings unavailable or refused\n');
	exit(1);
}
