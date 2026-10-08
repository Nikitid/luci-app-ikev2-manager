// Local activation bookkeeping. No device HTTP or RPC writer calls this.
'use strict';
import { lstat, open, readfile, readlink, lsdir, writefile, chmod, rename } from 'fs';
import { sha256 } from 'digest';
import { read_committed_client_state } from './client-access-store.uc';
import { validate_client_subnet } from './client-access.uc';
import { compile_client_path, client_sources_file } from './client-access-path.uc';

function safe_directory(directory) {
	let info = lstat(directory);
	if (info?.type != 'directory' || info.uid != 0 || info.mode != 0700) die('unsafe runtime');
}
function protected_read(path, limit) {
	let info = lstat(path);
	if (info?.type != 'file' || info.uid != 0 || info.mode != 0600 || info.nlink != 1 || info.size > limit)
		die('unsafe activation file');
	let file = open(path, 're');
	if (!file) die('missing activation file');
	let body = file.read(limit + 1); file.close();
	if (type(body) != 'string' || length(body) > limit) die('oversized activation file');
	return body;
}
function process_owner(directory, pid, start) {
	if (type(pid) != 'int' || pid < 2 || pid > 2147483647) die('invalid process');
	let process = '/proc/' + pid;
	if (lstat(process)?.uid != 0 || readlink(process + '/exe') != '/usr/bin/sing-box') die('foreign process');
	let command = split(readfile(process + '/cmdline') ?? '', chr(0));
	if (length(command) != 5 || command[1] != 'run' || command[2] != '-c' ||
		command[3] != directory + '/proxy.json' || command[4] != '') die('foreign command');
	let stats = split(readfile(process + '/stat') ?? '', ' ');
	if (stats[1] != '(sing-box)' || stats[2] == 'Z' || !match(stats[21] ?? '', /^[0-9]+$/) ||
		(start != null && stats[21] != start)) die('replaced process');
	return { version: 1, proxy_pid: pid, proxy_start: stats[21] };
}
function atomic_write(path, value) {
	if (!writefile(path + '.new', sprintf('%J\n', value)) || !chmod(path + '.new', 0600) || !rename(path + '.new', path))
		die('unable to record activation');
}
function listeners_owned(pid, port) {
	let prefix = '/proc/' + pid, sockets = {};
	for (let fd in lsdir(prefix + '/fd') ?? []) {
		let link = readlink(prefix + '/fd/' + fd);
		if (link != null) sockets[link] = true;
	}
	for (let protocol in [ 'tcp', 'udp' ]) {
		let found = false;
		for (let line in split(readfile(prefix + '/net/' + protocol) ?? '', '\n')) {
			let fields = filter(split(trim(line), ' '), item => length(item));
			if (fields[1] == sprintf('0100007F:%04X', port) &&
				(protocol != 'tcp' || fields[3] == '0A') && sockets['socket:[' + fields[9] + ']']) found = true;
		}
		if (!found) die('owned listener unavailable');
	}
}

function route_range(destination) {
 let parts = split(destination, '/'), octets = split(parts[0], '.');
 if (length(octets) != 4 || (length(parts) > 1 && !match(parts[1], /^[0-9]+$/))) die('invalid kernel route');
 let address = 0, prefix = length(parts) == 1 ? 32 : +parts[1], size = 1;
 if (prefix < 0 || prefix > 32) die('invalid route prefix');
 for (let octet in octets) {
  if (!match(octet, /^[0-9]{1,3}$/) || +octet > 255) die('invalid route address');
  address = address * 256 + +octet;
 }
 for (let bit = prefix; bit < 32; bit++) size *= 2;
 let first = address - address % size;
 return { first: first, last: first + size - 1 };
}
function route_slots(directory, plan, rules, routes) {
 let subnet = plan.virtual_subnet, range = validate_client_subnet(subnet), lease = null;
 if (lstat(directory + '/route-owner.json')) {
  lease = json(protected_read(directory + '/route-owner.json', 4096));
  if (type(lease) != 'object' || length(keys(lease)) != 2 || lease.version !== 1 || lease.subnet != subnet)
   die('different route ownership');
 }
 if (type(rules) != 'array' || type(routes) != 'array') die('missing route inventory');
 let rule_present = false, route_present = false;
 for (let rule in rules) {
  if (rule.priority != 10998 && '' + rule.table != '1506') continue;
  if (!lease || rule.priority != 10998 || '' + rule.table != '1506' || rule.src != 'all' ||
   rule.iif != 'ipsec-in' || rule.dst + '/' + rule.dstlen != subnet ||
   rule.fwmark != null || rule.action != null || rule_present) die('foreign rule slot');
  rule_present = true;
 }
 for (let route in routes) {
  if ('' + route.table == '1506') {
   if (!lease || route.type != 'local' || route.dst != subnet || route.dev != 'lo' ||
    route.gateway != null || route_present) die('foreign route slot');
   route_present = true; continue;
  }
  if (route.dst == 'default' || route.dst == '0.0.0.0/0') continue;
  let other = route_range(route.dst ?? '');
  if (range.first <= other.last && other.first <= range.last) die('overlapping route');
 }
 // Record intent before either mutation, so interrupted partial setup is recoverable.
 atomic_write(directory + '/route-owner.json', { version: 1, subnet: subnet });
 print(sprintf('%J\n', { rule_present: rule_present, route_present: route_present }));
}

try {
	let mode = ARGV[0];
	if (mode == 'prepare' && length(ARGV) == 7) {
		print(sprintf('%J\n', compile_client_path({ version: 1, state: read_committed_client_state(ARGV[1]),
			exit_link: ARGV[2], dns_address: ARGV[3], dns_port: +ARGV[4], listen_port: +ARGV[5], runtime_dir: ARGV[6] })));
	} else if (mode == 'sources' && length(ARGV) == 3) {
		// Which tunnel addresses belong, right now, to devices assigned each
		// service. Written only on change: the proxy rereads a changed file.
		safe_directory(ARGV[1]);
		let plan = json(protected_read(ARGV[2], 33554432));
		if (type(plan.sources) != 'object') die('missing sources');
		for (let service, addresses in plan.sources) {
			if (!(length(service) <= 48 ? match(service, /^[a-z0-9][a-z0-9_-]*$/) : null) || type(addresses) != 'array') die('invalid sources');
			for (let address in addresses)
				if (!match(address, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/)) die('invalid source address');
			let wanted = { version: 3, rules: length(addresses) ? [ { ip_cidr: map(sort(addresses), address => address + '/32') } ] : [] };
			let path = client_sources_file(ARGV[1], service), current = null;
			try { current = protected_read(path, 1048576); } catch (error) { current = null; }
			if (current != sprintf('%J\n', wanted)) atomic_write(path, wanted);
		}
	} else if (mode == 'routes' && length(ARGV) == 5) {
		safe_directory(ARGV[1]);
		route_slots(ARGV[1], json(protected_read(ARGV[2], 33554432)), json(readfile(ARGV[3])), json(readfile(ARGV[4])));
	} else if (mode == 'owner' && length(ARGV) == 2) {
		safe_directory(ARGV[1]);
		let owner = json(protected_read(ARGV[1] + '/proxy-owner.json', 4096));
		if (type(owner) != 'object' || length(keys(owner)) != 4 || owner.version !== 1 ||
			type(owner.proxy_start) != 'string') die('invalid ownership');
		print(process_owner(ARGV[1], owner.proxy_pid, owner.proxy_start).proxy_pid);
	} else if (mode == 'record' && length(ARGV) == 3) {
		safe_directory(ARGV[1]);
		let owner = process_owner(ARGV[1], +ARGV[2], null);
		owner.config_sha256 = sha256(protected_read(ARGV[1] + '/proxy.json', 16777216));
		atomic_write(ARGV[1] + '/proxy-owner.json', owner);
	} else if (mode == 'stamp' && length(ARGV) == 5) {
		let directory = ARGV[1]; safe_directory(directory);
		let plan = json(protected_read(ARGV[3], 33554432)), state = read_committed_client_state(ARGV[2]);
		if (plan.generation !== state.generation || plan.exit !== state.publication.exit ||
			!(length(ARGV[4]) == 64 ? match(ARGV[4], /^[a-f0-9]+$/) : null)) die('stale activation');
		let raw = protected_read(directory + '/proxy.json', 16777216);
		if (raw != sprintf('%J\n', plan.config)) die('different activation config');
		let owner = json(protected_read(directory + '/proxy-owner.json', 4096));
		if (owner.config_sha256 != sha256(raw)) die('unapplied config');
		owner = process_owner(directory, owner.proxy_pid, owner.proxy_start);
		listeners_owned(owner.proxy_pid, plan.config.inbounds[0].listen_port);
		atomic_write(directory + '/path-ready.json', { version: 1, generation: plan.generation, exit: plan.exit,
			config_sha256: sha256(raw), nft_sha256: ARGV[4], proxy_pid: owner.proxy_pid, proxy_start: owner.proxy_start });
	} else die('invalid activation command');
} catch (error) {
	warn('client-access-path-control: activation evidence unavailable\n'); exit(1);
}
