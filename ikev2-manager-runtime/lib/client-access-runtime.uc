// Local controller bridge. Files and SA evidence are never supplied by HTTP.
'use strict';
import { open } from 'fs';
import { read_client_state } from './client-access-store.uc';
import { compile_client_denial, reconcile_client_authorization } from './client-access-authorization.uc';

try {
	if (length(ARGV) != 4 || (ARGV[0] != 'close' && ARGV[0] != 'live' && ARGV[0] != 'subnet'))
		die('invalid controller arguments');
	let state = read_client_state(ARGV[1]);
	if (ARGV[0] == 'subnet') {
		print(state.publication.virtual_subnet);
		exit(0);
	}
	let compiled, mode = 'closed';
	// Nobody to admit: no device at all, or none that is open.
	if (ARGV[0] == 'close' || !length(filter(state.api.devices, device => device.enabled))) {
		compiled = compile_client_denial(state.publication.virtual_subnet);
	} else {
		let pool = split(ARGV[2], '-');
		if (length(pool) != 2)
			die('invalid inbound pool');
		let file = open(ARGV[3], 're');
		if (file == null)
			die('missing session snapshot');
		let raw = file.read(16777217);
		file.close();
		if (type(raw) != 'string' || length(raw) > 16777216)
			die('invalid session snapshot size');
		compiled = reconcile_client_authorization({ version: 1,
			pool: { first: pool[0], last: pool[1] }, api: state.api,
			snapshot: json(raw), lease_seconds: 15 });
		mode = 'ready';
	}
	// For every service published to clients, the tunnel addresses of the
	// admitted sessions whose device was assigned it.
	let sources = {}, assigned = {};
	for (let service in state.publication.services)
		if (service.client_access && length(service.domains)) sources[service.id] = [];
	for (let device in state.publication.devices)
		if (device.enabled) assigned[device.id] = device.selected_services;
	for (let session in compiled.sessions ?? [])
		for (let service in assigned[session.identity] ?? [])
			if (sources[service] != null && index(sources[service], session.address) < 0) push(sources[service], session.address);
	print(sprintf('%J\n', { generation: state.generation, exit: state.publication.exit, mode: mode, sources: sources,
		grants: length(compiled.tcp) + length(compiled.udp), sessions: compiled.sessions ?? [], nft: compiled.nft }));
} catch (error) {
	warn('client-access-runtime: local evidence unavailable\n');
	exit(1);
}
